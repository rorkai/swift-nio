//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

//
import XCTest

@testable import NIOCore

#if os(Windows)
import WinSDK
#endif

class IOErrorTest: XCTestCase {
    func testMemoryLayoutBelowThreshold() {
        XCTAssert(MemoryLayout<IOError>.size <= 24)
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testDeprecatedAPIStillFunctional() {
        XCTAssertNoThrow(IOError(errnoCode: 1, function: "anyFunc"))
    }

    #if os(Windows)
    func testWindowsErrorCodesPreserveTheirDomains() {
        let windowsError = IOError(windows: DWORD(ERROR_ACCESS_DENIED), reason: "CreateFileW")
        let winsockError = IOError(winsock: WSAEADDRINUSE, reason: "bind")

        XCTAssertEqual(windowsError.windowsErrorCode, DWORD(ERROR_ACCESS_DENIED))
        XCTAssertNil(windowsError.winsockErrorCode)
        XCTAssertEqual(winsockError.winsockErrorCode, WSAEADDRINUSE)
        XCTAssertNil(winsockError.windowsErrorCode)
    }
    #endif
}
