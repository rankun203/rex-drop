import Foundation

struct DropFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CollisionPolicy: String { case ask, keepBoth, replace }

struct LocalConflict: LocalizedError, CustomStringConvertible {
    let paths: [String]
    var recoveryDirectory: String? = nil
    var errorDescription: String? {
        "\(paths.count) destination item(s) already exists. Choose Keep Both or Replace." +
            (recoveryDirectory.map { " Copies retained for recovery in \($0)." } ?? "")
    }
    var description: String { errorDescription ?? "Destination items already exist." }
}

struct DropProgress {
    let phase: String
    let currentFile: String
    let completedFiles: Int
    let totalFiles: Int
    let fraction: Double?
    let completedBytes: Int64?
    let totalBytes: Int64?

    init(phase: String, currentFile: String, completedFiles: Int, totalFiles: Int, fraction: Double?,
         completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.phase = phase; self.currentFile = currentFile
        self.completedFiles = completedFiles; self.totalFiles = totalFiles; self.fraction = fraction
        self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}
