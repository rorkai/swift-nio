//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !os(WASI)

#if os(Windows)
import CNIOWindows
import NIOConcurrencyHelpers
import NIOCore
import WinSDK

/// Describes one attempt to fill a dynamically sized wide-string buffer.
///
/// This type remains file-scoped because generic functions cannot declare
/// nested types.
private enum WideStringBufferResult {
    case filled(String)
    case insufficientCapacity
    case failed(DWORD)
}

extension SelectorEventSet {
    /// The WSAPoll flags that correspond to this selector interest set.
    ///
    /// WSAPoll reports error and hangup states without explicit interest flags.
    var wsaPollEventSet: Int16 {
        var result: Int16 = 0
        if self.contains(.read) {
            result |= Int16(WinSDK.POLLRDNORM)
        }
        if self.contains(.write) || self.contains(.writeEOF) {
            result |= Int16(WinSDK.POLLWRNORM)
        }
        return result
    }

    /// Creates selector events from the flags returned by WSAPoll.
    @usableFromInline
    init(wsaPollEventSet: Int16) {
        self.rawValue = 0
        let mapped = Int32(wsaPollEventSet)
        if mapped & WinSDK.POLLRDNORM != 0 {
            self.formUnion(.read)
        }
        if mapped & WinSDK.POLLWRNORM != 0 {
            self.formUnion(.write)
        }
        if mapped & WinSDK.POLLERR != 0 {
            self.formUnion(.error)
        }
        if mapped & WinSDK.POLLHUP != 0 {
            self.formUnion(.reset)
        }
        if mapped & WinSDK.POLLNVAL != 0 {
            preconditionFailure("Invalid fd supplied.")
        }
    }
}

extension Selector: _SelectorBackendProtocol {

    func initialiseState0() throws {
        self.pollFDs.reserveCapacity(16)
        self.deregisteredPollIndexes.reserveCapacity(16)

        // WSAPoll cannot consume an asynchronous procedure call while blocked.
        // A private socket pair provides a pollable wakeup without spinning or
        // reserving a TCP port.
        let wakeupSockets = try Self.makeWakeupSocketPair()
        self.wakeupReadSocket = wakeupSockets.read
        self.wakeupWriteSocket = wakeupSockets.write

        // Index zero stays reserved for wakeups and never appears in the public
        // descriptor lookup.
        let wakeupPollFD = pollfd(
            fd: UInt64(wakeupSockets.read),
            events: Int16(WinSDK.POLLRDNORM),
            revents: 0
        )
        self.pollFDs.append(wakeupPollFD)

        self.lifecycleState = .open
    }

    /// Creates connected local sockets that can interrupt WSAPoll.
    private static func makeWakeupSocketPair() throws -> (
        read: NIOBSDSocket.Handle,
        write: NIOBSDSocket.Handle
    ) {
        let socketPath = try Self.makeWakeupSocketPath()

        // Create the listener socket. The listener and the on-disk socket path
        // are only needed long enough to bootstrap the connected pair, so we
        // tear them down unconditionally on the way out.
        let listenerSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)
        defer {
            _ = try? NIOBSDSocket.close(socket: listenerSocket)
            // The wide API preserves Unicode and long temporary paths during
            // cleanup.
            _ = socketPath.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        }

        var address = sockaddr_un()
        address.sun_family = ADDRESS_FAMILY(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw IOError(
                windows: DWORD(ERROR_FILENAME_EXCED_RANGE),
                reason: "wakeup socket path exceeds sockaddr_un.sun_path"
            )
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBufferPointer { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(source))
            }
        }

        // Binding requires the generic pointer while the original structure
        // length preserves the address-family payload.
        let addressLength = socklen_t(MemoryLayout.size(ofValue: address))
        try withUnsafePointer(to: &address) { addressPointer in
            try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try NIOBSDSocket.bind(
                    socket: listenerSocket,
                    address: socketPointer,
                    address_len: addressLength
                )
            }
        }

        if WinSDK.listen(listenerSocket, 1) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "listen")
        }

        let writeSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)

        do {
            try withUnsafePointer(to: &address) { addressPointer in
                try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard
                        try NIOBSDSocket.connect(
                            socket: writeSocket,
                            address: socketAddress,
                            address_len: addressLength
                        )
                    else {
                        throw IOError(winsock: WSAGetLastError(), reason: "connect")
                    }
                }
            }

            let readSocket = WinSDK.accept(listenerSocket, nil, nil)
            if readSocket == INVALID_SOCKET {
                throw IOError(winsock: WSAGetLastError(), reason: "accept")
            }

            do {
                try NIOBSDSocket.setNonBlocking(socket: readSocket)
                try NIOBSDSocket.setNonBlocking(socket: writeSocket)
                return (read: readSocket, write: writeSocket)
            } catch {
                try? NIOBSDSocket.close(socket: readSocket)
                throw error
            }
        } catch {
            _ = try? NIOBSDSocket.close(socket: writeSocket)
            throw error
        }
    }

    /// Generates an unpredictable wakeup socket path in the temporary directory.
    private static func makeWakeupSocketPath() throws -> String {
        let temporaryDirectory = try Self.readWideString(
            initialCapacity: DWORD(MAX_PATH) + 1,
            maximumCapacity: DWORD(Int16.max),
            reason: "GetTempPathW"
        ) { buffer in
            GetTempPathW(DWORD(buffer.count), buffer.baseAddress)
        }
        let processID = GetCurrentProcessId()
        let randomSuffix = UInt64.random(in: .min ... .max)
        return "\(temporaryDirectory)nio-wakeup-\(processID)-\(String(randomSuffix, radix: 16)).sock"
    }

    /// Reads a null-terminated UTF-16 value from a Windows API.
    ///
    /// The allocation grows until the value fits or reaches the maximum
    /// capacity. The API must return zero on failure, the character count on
    /// success, or a count at least as large as the buffer when more space is
    /// required.
    private static func readWideString(
        initialCapacity: DWORD,
        maximumCapacity: DWORD,
        reason: String,
        using body: (UnsafeMutableBufferPointer<WCHAR>) -> DWORD
    ) throws -> String {
        var bufferCount = max(1, min(initialCapacity, maximumCapacity))
        while bufferCount <= maximumCapacity {
            let result: WideStringBufferResult = withUnsafeTemporaryAllocation(
                of: WCHAR.self,
                capacity: Int(bufferCount)
            ) { buffer in
                let count = body(buffer)
                switch count {
                case 0:
                    return .failed(GetLastError())
                case 1..<DWORD(buffer.count):
                    return .filled(String(decodingCString: buffer.baseAddress!, as: UTF16.self))
                default:
                    return .insufficientCapacity
                }
            }
            switch result {
            case .filled(let string):
                return string
            case .failed(let win32Error):
                throw IOError(windows: win32Error, reason: reason)
            case .insufficientCapacity:
                bufferCount *= 2
            }
        }
        throw IOError(windows: DWORD(ERROR_INSUFFICIENT_BUFFER), reason: reason)
    }

    func deinitAssertions0() {
        assert(
            self.wakeupReadSocket == NIOBSDSocket.invalidHandle,
            "wakeupReadSocket == \(self.wakeupReadSocket) in deinitAssertions0, forgot close?"
        )
        assert(
            self.wakeupWriteSocket == NIOBSDSocket.invalidHandle,
            "wakeupWriteSocket == \(self.wakeupWriteSocket) in deinitAssertions0, forgot close?"
        )
    }

    /// Drains every pending wakeup byte without blocking the event-loop thread.
    @usableFromInline
    func drainWakeupSocket() throws {
        while true {
            let received = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
                WinSDK.recv(
                    self.wakeupReadSocket,
                    buffer.baseAddress!,
                    CInt(buffer.count),
                    0
                )
            }
            if received > 0 {
                continue
            }
            if received == 0 {
                throw EventLoopError.shutdown
            }

            let error = WSAGetLastError()
            if error == WSAEWOULDBLOCK {
                return
            }
            throw IOError(winsock: error, reason: "recv (wakeup)")
        }
    }

    /// Removes deferred poll entries and refreshes indexes after event delivery.
    ///
    /// Generic deregistration owns the registration dictionary. Leaving it
    /// untouched here preserves a replacement that reused the same descriptor.
    @usableFromInline
    func compactDeregisteredPollEntries() {
        guard !self.deregisteredPollIndexes.isEmpty else {
            return
        }

        var writeIndex = 0
        for readIndex in self.pollFDs.indices {
            if self.deregisteredPollIndexes.contains(readIndex) {
                continue
            }
            if writeIndex != readIndex {
                self.pollFDs[writeIndex] = self.pollFDs[readIndex]
                if writeIndex != 0 {
                    let descriptor = NIOBSDSocket.Handle(self.pollFDs[writeIndex].fd)
                    self.pollIndexByDescriptor[descriptor] = writeIndex
                }
            }
            writeIndex += 1
        }
        self.pollFDs.removeLast(self.pollFDs.count - writeIndex)
        self.deregisteredPollIndexes.removeAll(keepingCapacity: true)
    }

    @inlinable
    func whenReady0(
        strategy: SelectorStrategy,
        onLoopBegin: () -> Void,
        _ body: (SelectorEvent<R>) throws -> Void
    ) throws {
        let time: Int32 =
            switch strategy {
            case .now:
                0

            case .block:
                -1

            case .blockUntilTimeout(let timeAmount):
                Int32(clamping: timeAmount.nanoseconds / 1_000_000)
            }

        precondition(
            !self.pollFDs.isEmpty,
            "pollFDs should never be empty here, since we need an eventFD for waking up on demand"
        )
        let result = self.pollFDs.withUnsafeMutableBufferPointer { ptr in
            WSAPoll(ptr.baseAddress!, UInt32(ptr.count), time)
        }
        let pollError = result == WinSDK.SOCKET_ERROR ? WSAGetLastError() : nil
        defer {
            self.compactDeregisteredPollEntries()
        }

        if result > 0 {
            for i in self.pollFDs.indices {
                guard !self.deregisteredPollIndexes.contains(i) else {
                    continue
                }
                let pollFD = self.pollFDs[i]
                guard pollFD.revents != 0 else {
                    continue
                }
                self.pollFDs[i].revents = 0
                let fd = pollFD.fd

                if NIOBSDSocket.Handle(fd) == self.wakeupReadSocket {
                    try self.drainWakeupSocket()
                    continue
                }

                // Callbacks may deregister descriptors while results are still
                // being delivered, so stale entries are ignored.
                guard let registration = self.registrations[Int(fd)] else {
                    continue
                }

                var selectorEvent = SelectorEventSet(wsaPollEventSet: pollFD.revents)
                selectorEvent = selectorEvent.intersection(registration.interested)

                guard selectorEvent != ._none else {
                    continue
                }

                try body((SelectorEvent(io: selectorEvent, registration: registration)))
            }
        } else if let pollError {
            throw IOError(winsock: pollError, reason: "WSAPoll")
        }
    }

    func register0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        interested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        let poll = pollfd(fd: UInt64(fileDescriptor), events: interested.wsaPollEventSet, revents: 0)
        self.pollIndexByDescriptor[fileDescriptor] = self.pollFDs.count
        self.pollFDs.append(poll)
    }

    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        guard let index = self.pollIndexByDescriptor[fileDescriptor] else {
            preconditionFailure("Cannot reregister unknown descriptor \(fileDescriptor)")
        }
        self.pollFDs[index].events = newInterested.wsaPollEventSet
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        guard let index = self.pollIndexByDescriptor.removeValue(forKey: fileDescriptor) else {
            preconditionFailure("Cannot deregister unknown descriptor \(fileDescriptor)")
        }
        self.deregisteredPollIndexes.insert(index)
    }

    func wakeup0() throws {
        // A socket byte interrupts WSAPoll when another thread schedules work.
        try self.externalSelectorFDLock.withLock {
            guard self.wakeupWriteSocket != NIOBSDSocket.invalidHandle else {
                throw EventLoopError.shutdown
            }
            var byte: UInt8 = 0
            let result = withUnsafePointer(to: &byte) { ptr in
                WinSDK.send(self.wakeupWriteSocket, ptr, 1, 0)
            }
            if result == SOCKET_ERROR {
                let error = WSAGetLastError()
                if error != WSAEWOULDBLOCK {
                    throw IOError(winsock: error, reason: "send (wakeup)")
                }
            }
        }
    }

    func close0() throws {
        // Wakeup and close can race, so the same lock protects socket ownership.
        self.externalSelectorFDLock.withLock {
            if self.wakeupReadSocket != NIOBSDSocket.invalidHandle {
                try? NIOBSDSocket.close(socket: self.wakeupReadSocket)
                self.wakeupReadSocket = NIOBSDSocket.invalidHandle
            }
            if self.wakeupWriteSocket != NIOBSDSocket.invalidHandle {
                try? NIOBSDSocket.close(socket: self.wakeupWriteSocket)
                self.wakeupWriteSocket = NIOBSDSocket.invalidHandle
            }
            self.pollFDs.removeAll()
            self.pollIndexByDescriptor.removeAll()
            self.deregisteredPollIndexes.removeAll()
        }
    }
}
#endif
#endif  // !os(WASI)
