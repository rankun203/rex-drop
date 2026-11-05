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
}
