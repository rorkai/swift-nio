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
    /// Wraps an immutable kernel thread handle that may cross thread boundaries.
    ///
    /// Long-lived values own duplicated handles. A temporary value may wrap the
    /// current thread's pseudo-handle only while a nonescaping API call runs.
    struct ThreadHandle: @unchecked Sendable {
        /// Native handle passed to Windows thread APIs.
        let handle: HANDLE
    }

    typealias ThreadSpecificKey = DWORD
    typealias ThreadSpecificKeyDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static func threadName(_ thread: ThreadOpsSystem.ThreadHandle) -> String? {
        var bufferPointer: PWSTR?
        GetThreadDescription(thread.handle, &bufferPointer)
        guard let bufferPointer else { return nil }
        let name = String(decodingCString: bufferPointer, as: UTF16.self)
        LocalFree(bufferPointer)
        return name
    }

    static func run(
        handle _: inout ThreadOpsSystem.ThreadHandle?,
        args: Box<NIOThread.ThreadBoxValue>
    ) {
        let argv0 = Unmanaged.passRetained(args).toOpaque()

        // FIXME(compnerd) this should use the `stdcall` calling convention
        let routine: @convention(c) (UnsafeMutableRawPointer?) -> CUnsignedInt = {
            guard let argument = $0 else {
                fatalError("_beginthreadex started without its thread arguments")
            }
            let boxed = Unmanaged<NIOThread.ThreadBox>.fromOpaque(argument).takeRetainedValue()
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
            let threadHandle = ThreadHandle(handle: realHandle)

            if let name = name {
                _ = name.withCString(encodedAs: UTF16.self) {
                    SetThreadDescription(threadHandle.handle, $0)
                }
            }

            body(NIOThread(handle: threadHandle, desiredName: name))

            return 0
        }

        // The thread publishes its own durable handle, so the bootstrap handle
        // can close immediately without ending the thread.
        let rawBootstrapHandle = _beginthreadex(nil, 0, routine, argv0, 0, nil)
        guard let bootstrapHandle = HANDLE(bitPattern: rawBootstrapHandle) else {
            Unmanaged<NIOThread.ThreadBox>.fromOpaque(argv0).release()
            fatalError("_beginthreadex failed with errno \(errno)")
        }
        CloseHandle(bootstrapHandle)
    }

    static func isCurrentThread(_ thread: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(thread.handle, GetCurrentThread())
    }

    /// Returns an owning duplicate of the current thread's pseudo-handle.
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

    /// Waits for the thread to exit without consuming its owning handle.
    static func waitForThread(_ thread: ThreadOpsSystem.ThreadHandle) {
        let waitResult = WaitForSingleObject(thread.handle, INFINITE)
        assert(waitResult == WAIT_OBJECT_0, "WaitForSingleObject: \(GetLastError())")
    }

    /// Consumes the owning handle after all synchronized access has finished.
    static func closeThreadHandle(_ thread: ThreadOpsSystem.ThreadHandle) {
        CloseHandle(thread.handle)
    }

    /// Waits for the thread to exit and consumes its owning handle.
    static func joinThread(_ thread: ThreadOpsSystem.ThreadHandle) {
        self.waitForThread(thread)
        self.closeThreadHandle(thread)
    }

    static func allocateThreadSpecificValue(destructor: @escaping ThreadSpecificKeyDestructor) -> ThreadSpecificKey {
        FlsAlloc(destructor)
    }

    static func deallocateThreadSpecificValue(_ key: ThreadSpecificKey) {
        let didFree = FlsFree(key)
        precondition(didFree, "FlsFree: \(GetLastError())")
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
