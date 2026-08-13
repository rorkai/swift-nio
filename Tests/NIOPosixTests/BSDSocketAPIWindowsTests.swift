//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)
import NIOCore
import WinSDK
import XCTest

@testable import NIOPosix

final class BSDSocketAPIWindowsTests: XCTestCase {
    func testReadReturnsWouldBlockWhenNoDataIsAvailable() throws {
        try self.withConnectedSockets { client, _ in
            var byte: UInt8 = 0
            let result = try withUnsafeMutableBytes(of: &byte) {
                try client.read(pointer: $0)
            }

            XCTAssertEqual(.wouldBlock(0), result)
        }
    }

    func testWriteReturnsWouldBlockWhenTheSendBufferIsFull() throws {
        try self.withConnectedSockets { client, _ in
            let payload = [UInt8](repeating: 0xa5, count: 64 * 1024)
            var observedWouldBlock = false

            for _ in 0..<4_096 {
                let result = try payload.withUnsafeBytes {
                    try client.write(pointer: $0)
                }
                if case .wouldBlock(let writtenByteCount) = result {
                    XCTAssertEqual(0, writtenByteCount)
                    observedWouldBlock = true
                    break
                }
            }

            XCTAssertTrue(observedWouldBlock, "The nonblocking socket never exhausted its send buffer.")
        }
    }

    func testWritevReturnsWouldBlockWhenTheSendBufferIsFull() throws {
        try self.withConnectedSockets { client, _ in
            try self.fillSendBuffer(client)

            var payload = [UInt8](repeating: 0xa5, count: 16)
            let result = try payload.withUnsafeMutableBytes { bytes in
                var vector = IOVector(
                    iov_base: bytes.baseAddress,
                    iov_len: numericCast(bytes.count)
                )
                return try withUnsafePointer(to: &vector) {
                    try client.writev(
                        iovecs: UnsafeBufferPointer(start: $0, count: 1)
                    )
                }
            }

            XCTAssertEqual(.wouldBlock(0), result)
        }
    }

    private func withConnectedSockets(
        _ body: (Socket, Socket) throws -> Void
    ) throws {
        let server = try ServerSocket.bootstrap(
            protocolFamily: .inet,
            host: "127.0.0.1",
            port: 0
        )
        defer {
            XCTAssertNoThrow(try server.close())
        }

        let client = try Socket(protocolFamily: .inet, type: .stream)
        defer {
            XCTAssertNoThrow(try client.close())
        }
        try client.setOption(
            level: .socket,
            name: .so_sndbuf,
            value: CInt(1_024)
        )
        XCTAssertTrue(try client.connect(to: server.localAddress()))
        try client.setNonBlocking()

        let peer = try XCTUnwrap(server.accept())
        defer {
            XCTAssertNoThrow(try peer.close())
        }
        try peer.setOption(
            level: .socket,
            name: .so_rcvbuf,
            value: CInt(1_024)
        )

        try body(client, peer)
    }

    private func fillSendBuffer(_ socket: Socket) throws {
        let payload = [UInt8](repeating: 0xa5, count: 64 * 1024)
        for _ in 0..<4_096 {
            do {
                let result = try payload.withUnsafeBytes {
                    try socket.write(pointer: $0)
                }
                if case .wouldBlock = result {
                    return
                }
            } catch let error as IOError where error.winsockErrorCode == WSAEWOULDBLOCK {
                return
            }
        }
        XCTFail("The nonblocking socket never exhausted its send buffer.")
    }
}
#endif
