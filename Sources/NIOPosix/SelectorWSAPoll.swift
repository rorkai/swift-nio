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

/**
 * Represents one attempt to fill a wide-string buffer.
 *
 * A file-scoped type is required because generic methods cannot contain local
 * type declarations.
 */
private enum _WideStringFillResult {
    case filled(String)
    case insufficient
    case failed(DWORD)
}

extension SelectorEventSet {
    /**
     * Maps readable and writable interests to WSAPoll flags.
     *
     * Error and hangup states are reported without explicit interest flags.
     */
    var wsaPollEvent: Int16 {
        var result: Int16 = 0
        if self.contains(.read) {
            result |= Int16(WinSDK.POLLRDNORM)
        }
        if self.contains(.write) || self.contains(.writeEOF) {
            result |= Int16(WinSDK.POLLWRNORM)
        }
        return result
    }

    /**
     * Maps WSAPoll result flags to selector events.
     */
    @usableFromInline
    init(revents: Int16) {
        self.rawValue = 0
        let mapped = Int32(revents)
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
        self.deregisteredFDs.reserveCapacity(16)

        // WSAPoll cannot consume an asynchronous procedure call while blocked.
        // A private socket pair provides a pollable wakeup without spinning or
        // reserving a TCP port.
        let (readSocket, writeSocket) = try Self.createWakeupSocketPair()
        self.wakeupReadSocket = readSocket
        self.wakeupWriteSocket = writeSocket

        // Index zero stays reserved for wakeups and never appears in the public
        // descriptor lookup.
        let wakeupPollFD = pollfd(fd: UInt64(readSocket), events: Int16(WinSDK.POLLRDNORM), revents: 0)
        self.pollFDs.append(wakeupPollFD)

        self.lifecycleState = .open
    }

    /**
     * Creates connected local sockets that can interrupt WSAPoll.
     */
    private static func createWakeupSocketPair() throws -> (NIOBSDSocket.Handle, NIOBSDSocket.Handle) {
        let socketPath = try Self.generateUniqueSocketPath()

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

        var addr = sockaddr_un()
        addr.sun_family = ADDRESS_FAMILY(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "Socket path too long")
        withUnsafeMutableBytes(of: &addr.sun_path) { destPtr in
            pathBytes.withUnsafeBufferPointer { srcPtr in
                destPtr.copyMemory(from: UnsafeRawBufferPointer(srcPtr))
            }
        }

        // Binding requires the generic pointer while the original structure
        // length preserves the address-family payload.
        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        try withUnsafePointer(to: &addr) { addrPtr in
            try addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try NIOBSDSocket.bind(
                    socket: listenerSocket,
                    address: socketPointer,
                    address_len: addrLen
                )
            }
        }

        if WinSDK.listen(listenerSocket, 1) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "listen")
        }

        let writeSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)

        do {
            try withUnsafePointer(to: &addr) { addrPtr in
                try addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    guard
                        try NIOBSDSocket.connect(
                            socket: writeSocket,
                            address: sockaddrPtr,
                            address_len: addrLen
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

            return (readSocket, writeSocket)
        } catch {
            _ = try? NIOBSDSocket.close(socket: writeSocket)
            throw error
        }
    }

    /**
     * Generates a unique socket path in the Windows temporary directory.
     */
    private static func generateUniqueSocketPath() throws -> String {
        // The wide API preserves Unicode paths, and an expanding buffer avoids
        // the legacy fixed path limit.
        let tempDir = try Self.fillWideStringBuffer(
            initialSize: DWORD(MAX_PATH) + 1,
            maxSize: DWORD(Int16.max),
            reason: "GetTempPath2W"
        ) { buffer in
            GetTempPath2W(DWORD(buffer.count), buffer.baseAddress)
        }

        // Process and thread identifiers plus a monotonic tick distinguish
        // concurrent selectors.
        let processID = GetCurrentProcessId()
        let threadID = GetCurrentThreadId()
        let tickCount = GetTickCount64()
        let uniqueID = "\(processID)-\(threadID)-\(tickCount)"

        return "\(tempDir)nio-wakeup-\(uniqueID).sock"
    }

    /**
     * Calls a Windows API with an expanding null-terminated UTF-16 buffer.
     *
     * A zero result indicates a system error. A count at least as large as the
     * buffer requests another allocation. Any other positive count represents
     * a complete value without its null terminator.
     */
    private static func fillWideStringBuffer(
        initialSize: DWORD,
        maxSize: DWORD,
        reason: String,
        _ body: (UnsafeMutableBufferPointer<WCHAR>) -> DWORD
    ) throws -> String {
        var bufferCount = max(1, min(initialSize, maxSize))
        while bufferCount <= maxSize {
            let result: _WideStringFillResult = withUnsafeTemporaryAllocation(
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
                    return .insufficient
                }
            }
            switch result {
            case .filled(let string):
                return string
            case .failed(let win32Error):
                throw IOError(windows: win32Error, reason: reason)
            case .insufficient:
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

        if result > 0 {
            for i in self.pollFDs.indices {
                let pollFD = self.pollFDs[i]
                guard pollFD.revents != 0 else {
                    continue
                }
                self.pollFDs[i].revents = 0
                let fd = pollFD.fd

                if NIOBSDSocket.Handle(fd) == self.wakeupReadSocket {
                    // Draining the byte rearms the next cross-thread wakeup.
                    var buffer: UInt8 = 0
                    _ = withUnsafeMutablePointer(to: &buffer) { ptr in
                        WinSDK.recv(self.wakeupReadSocket, ptr, 1, 0)
                    }
                    continue
                }

                // Callbacks may deregister descriptors while results are still
                // being delivered, so stale entries are ignored.
                guard let registration = self.registrations[Int(fd)] else {
                    continue
                }

                var selectorEvent = SelectorEventSet(revents: pollFD.revents)
                selectorEvent = selectorEvent.intersection(registration.interested)

                guard selectorEvent != ._none else {
                    continue
                }

                try body((SelectorEvent(io: selectorEvent, registration: registration)))
            }

            // Deferred removals keep indexes stable during callbacks. One
            // in-place pass updates shifted indexes and preserves the wakeup
            // socket at index zero.
            if !self.deregisteredFDs.isEmpty {
                var write = 0
                for read in 0..<self.pollFDs.count {
                    if self.deregisteredFDs.contains(read) {
                        continue
                    }
                    if write != read {
                        self.pollFDs[write] = self.pollFDs[read]
                        if write != 0 {
                            self.pollFDIndexes[NIOBSDSocket.Handle(self.pollFDs[write].fd)] = write
                        }
                    }
                    write += 1
                }
                self.pollFDs.removeLast(self.pollFDs.count - write)
                self.deregisteredFDs.removeAll(keepingCapacity: true)
            }
        } else if result == WinSDK.SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "WSAPoll")
        }
    }

    func register0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        interested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        let poll = pollfd(fd: UInt64(fileDescriptor), events: interested.wsaPollEvent, revents: 0)
        self.pollFDIndexes[fileDescriptor] = self.pollFDs.count
        self.pollFDs.append(poll)
    }

    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDIndexes[fileDescriptor] {
            self.pollFDs[index].events = newInterested.wsaPollEvent
        }
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDIndexes.removeValue(forKey: fileDescriptor) {
            self.deregisteredFDs.insert(index)
        }
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
                throw IOError(winsock: WSAGetLastError(), reason: "send (wakeup)")
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
            self.pollFDIndexes.removeAll()
            self.deregisteredFDs.removeAll()
        }
    }
}
#endif
#endif  // !os(WASI)
