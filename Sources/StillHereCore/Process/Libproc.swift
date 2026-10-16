import Darwin
import Foundation

/// Thin, synchronous wrappers over libproc and sysctl. Each call takes microseconds;
/// callers run them off the main actor.
enum Libproc {
    enum Lookup<Value> {
        case found(Value)
        case notFound
        case denied
        case failed(errno: Int32)
    }

    struct BSDInfo {
        var ppid: Int32
        var uid: UInt32
        var name: String
        var startTime: Date
    }

    static func bsdInfo(
        _ pid: Int32,
        read: (Int32, inout proc_bsdinfo, Int32) -> Int32 = { pid, info, size in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        }
    ) -> Lookup<BSDInfo> {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let received = read(pid, &info, size)
        let error = errno
        guard received == size else {
            // Only an explicit missing-process error establishes exit. Short data,
            // unavailable inspection, and other syscall errors remain unresolved.
            guard received == 0 else { return .failed(errno: EIO) }
            switch error {
            case ESRCH: return .notFound
            case EPERM, EACCES: return .denied
            default: return .failed(errno: error == 0 ? EIO : error)
            }
        }
        let longName = cString(fromTuple: info.pbi_name)
        let name = longName.isEmpty ? cString(fromTuple: info.pbi_comm) : longName
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        return .found(BSDInfo(ppid: Int32(info.pbi_ppid), uid: info.pbi_uid, name: name, startTime: start))
    }

    /// Every PID on the system (other users' included; callers filter by uid).
    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(fromTuple: info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Raw `KERN_PROCARGS2` bytes, or nil when unavailable.
    static func procArgs(_ pid: Int32) -> [UInt8]? {
        var size = argMax
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    private static let argMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }()

    private static func cString<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
