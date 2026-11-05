import Foundation
import Darwin

extension DropService {
    static func processArgv(_ pid: Int32) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 8, size <= 16 * 1024 * 1024 else {
            throw DropFailure("Cannot inspect this SSH process. Refresh and try again.")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else {
            throw DropFailure("SSH process changed during inspection.")
        }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc <= 65536, let executableEnd = bytes[4..<size].firstIndex(of: 0) else {
            throw DropFailure("Invalid SSH process arguments.")
        }
        var start = executableEnd + 1
        while start < size && bytes[start] == 0 { start += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            guard start < size, let end = bytes[start..<size].firstIndex(of: 0),
                  let word = String(bytes: bytes[start..<end], encoding: .utf8) else {
                throw DropFailure("Incomplete or unsupported SSH process arguments.")
            }
            result.append(word); start = end + 1
        }
        return result
    }

    static func processStart(_ pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else {
            throw DropFailure("Selected process has exited or cannot be inspected.")
        }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }
}
