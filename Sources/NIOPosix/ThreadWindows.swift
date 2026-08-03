//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
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

import WinSDK

typealias ThreadOpsSystem = ThreadOpsWindows
enum ThreadOpsWindows: ThreadOps {
    /**
     * Wraps an immutable kernel thread handle that may cross thread boundaries.
     *
     * The kernel manages handle references through a thread-safe table. This
     * wrapper establishes sendability without exposing mutable state.
     */
    struct ThreadHandle: @unchecked Sendable {
        let handle: HANDLE
    }

    typealias ThreadSpecificKey = DWORD
    typealias ThreadSpecificKeyDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static func threadName(_ thread: ThreadOpsSystem.ThreadHandle) -> String? {
        var pszBuffer: PWSTR?
        GetThreadDescription(thread.handle, &pszBuffer)
        guard let buffer = pszBuffer else { return nil }
        let string: String = String(decodingCString: buffer, as: UTF16.self)
        LocalFree(buffer)
        return string
    }

    static func run(
        handle: inout ThreadOpsSystem.ThreadHandle?,
        args: Box<NIOThread.ThreadBoxValue>
    ) {
        let argv0 = Unmanaged.passRetained(args).toOpaque()

        // FIXME(compnerd) this should use the `stdcall` calling convention
        let routine: @convention(c) (UnsafeMutableRawPointer?) -> CUnsignedInt = {
            let boxed = Unmanaged<NIOThread.ThreadBox>.fromOpaque($0!).takeRetainedValue()
            let (body, name) = (boxed.value.body, boxed.value.name)

            // A pseudo-handle is valid only in its originating thread. A real
            // handle lets another thread wait for completion and release it.
            var realHandle: HANDLE?
            let duplicated = DuplicateHandle(
                GetCurrentProcess(),
                GetCurrentThread(),
                GetCurrentProcess(),
                &realHandle,
                0,
                false,
                DWORD(DUPLICATE_SAME_ACCESS)
            )
            guard duplicated, let realHandle else {
                fatalError("DuplicateHandle failed: \(GetLastError())")
            }
            let hThread = ThreadHandle(handle: realHandle)

            if let name = name {
                _ = name.withCString(encodedAs: UTF16.self) {
                    SetThreadDescription(hThread.handle, $0)
                }
            }

            body(NIOThread(handle: hThread, desiredName: name))

            return 0
        }

        // The thread publishes its own durable handle, so the bootstrap handle
        // can close immediately without ending the thread.
        let bootstrapHandle = HANDLE(
            bitPattern: _beginthreadex(nil, 0, routine, argv0, 0, nil)
        )!
        CloseHandle(bootstrapHandle)
    }

    static func isCurrentThread(_ thread: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(thread.handle, GetCurrentThread())
    }

    static var currentThread: ThreadOpsSystem.ThreadHandle {
        // The temporary thread wrapper can outlive this call, so it needs an
        // owning handle rather than a context-bound pseudo-handle.
        var realHandle: HANDLE?
        let duplicated = DuplicateHandle(
            GetCurrentProcess(),
            GetCurrentThread(),
            GetCurrentProcess(),
            &realHandle,
            0,
            false,
            DWORD(DUPLICATE_SAME_ACCESS)
        )
        guard duplicated, let realHandle else {
            fatalError("DuplicateHandle failed: \(GetLastError())")
        }
        return ThreadHandle(handle: realHandle)
    }

    static func joinThread(_ thread: ThreadOpsSystem.ThreadHandle) {
        let dwResult: DWORD = WaitForSingleObject(thread.handle, INFINITE)
        assert(dwResult == WAIT_OBJECT_0, "WaitForSingleObject: \(GetLastError())")

        // joinThread consumes the owning handle after the kernel reports
        // completion.
        CloseHandle(thread.handle)
    }

    static func allocateThreadSpecificValue(destructor: @escaping ThreadSpecificKeyDestructor) -> ThreadSpecificKey {
        FlsAlloc(destructor)
    }

    static func deallocateThreadSpecificValue(_ key: ThreadSpecificKey) {
        let dwResult: Bool = FlsFree(key)
        precondition(dwResult, "FlsFree: \(GetLastError())")
    }

    static func getThreadSpecificValue(_ key: ThreadSpecificKey) -> UnsafeMutableRawPointer? {
        FlsGetValue(key)
    }

    static func setThreadSpecificValue(key: ThreadSpecificKey, value: UnsafeMutableRawPointer?) {
        FlsSetValue(key, value)
    }

    static func compareThreads(_ lhs: ThreadOpsSystem.ThreadHandle, _ rhs: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(lhs.handle, rhs.handle)
    }
}

#endif
#endif  // !os(WASI)
