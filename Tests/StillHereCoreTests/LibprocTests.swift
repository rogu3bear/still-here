import Darwin
import Foundation
import Testing
@testable import StillHereCore

@Suite struct LibprocBSDLookupTests {
    private func lookup(bytes: Int32 = 0, error: Int32) -> Libproc.Lookup<Libproc.BSDInfo> {
        Libproc.bsdInfo(500) { _, _, _ in
            errno = error
            return bytes
        }
    }

    @Test func missingPIDRequiresESRCH() {
        guard case .notFound = lookup(error: ESRCH) else {
            Issue.record("ESRCH must identify a missing PID"); return
        }
    }

    @Test func permissionErrorsRemainDenied() {
        for error in [EPERM, EACCES] {
            guard case .denied = lookup(error: error) else {
                Issue.record("Permission failure \(error) must remain denied"); continue
            }
        }
    }

    @Test func otherErrorsAndMissingErrnoRemainUnresolved() {
        for error in [Int32(0), EIO, EINVAL, EINTR] {
            guard case .failed(let actual) = lookup(error: error) else {
                Issue.record("Lookup failure \(error) must not establish process exit"); continue
            }
            #expect(actual == (error == 0 ? EIO : error))
        }
    }

    @Test func partialReplyCannotEstablishExitEvenWithStaleErrno() {
        let partial = Int32(MemoryLayout<proc_bsdinfo>.size - 1)
        guard case .failed(let code) = lookup(bytes: partial, error: ESRCH) else {
            Issue.record("Partial identity data must remain unresolved"); return
        }
        #expect(code == EIO)
    }

    @Test func completeReplyUsesItsDataRegardlessOfStaleErrno() {
        let result = Libproc.bsdInfo(500) { _, info, size in
            info.pbi_uid = 77
            info.pbi_start_tvsec = 1_800_000_000
            errno = ESRCH
            return size
        }
        guard case .found(let info) = result else {
            Issue.record("Complete identity data must remain usable"); return
        }
        #expect(info.uid == 77)
        #expect(info.startTime == Date(timeIntervalSince1970: 1_800_000_000))
    }
}

@Suite struct LibprocUserEnumerationTests {
    @Test func userFilterAndByteCountArePreserved() {
        let result = Libproc.pids(for: 501) { uid, buffer, _ in
            #expect(uid == 501)
            guard let buffer else { return 12 }
            for (index, pid) in [Int32(0), 100, 101].enumerated() {
                buffer.storeBytes(of: pid, toByteOffset: index * 4, as: Int32.self)
            }
            return 12
        }
        #expect(result == [100, 101])
    }

    @Test func failedAndPartialEnumerationsRemainUnknown() {
        #expect(Libproc.pids(for: 501) { _, _, _ in 0 } == nil)
        #expect(Libproc.pids(for: 501) { _, _, _ in -1 } == nil)
        #expect(Libproc.pids(for: 501) { _, buffer, _ in buffer == nil ? 4 : 3 } == nil)
        #expect(Libproc.pids(for: 501) { _, buffer, size in buffer == nil ? 4 : size } == nil)
    }

    @Test func fullBufferIsRetriedBeforeUsingTheSnapshot() {
        var calls = 0
        let result = Libproc.pids(for: 501) { _, buffer, size in
            calls += 1
            guard let buffer else { return 4 }
            if calls == 2 { return size }
            buffer.storeBytes(of: Int32(100), as: Int32.self)
            return 4
        }
        #expect(calls == 3)
        #expect(result == [100])
    }
}
