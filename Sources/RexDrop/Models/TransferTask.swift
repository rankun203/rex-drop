import AppKit

enum TransferState: String {
    case conflict = "Already exists", queued = "Queued", running = "Sending", paused = "Paused", cancelling = "Cancelling", cancelled = "Cancelled", failed = "Failed", complete = "Complete"
    var active: Bool { [.queued, .running, .paused, .cancelling].contains(self) }
}
final class TransferTask {
    let id = UUID()
    var target: [String: Any]
    let paths: [String]
    var state = TransferState.queued
    var control = DropTaskControl()
    var phase = "Queued", currentFile = "", completedFiles = 0, totalFiles = 0
    var fraction: Double?
    var completedBytes: Int64?
    var totalBytes: Int64?
    var percentage: Int? {
        if let done = completedBytes, let total = totalBytes, total > 0 {
            return Int(min(100, max(0, Double(max(0, done)) / Double(total) * 100)))
        }
        guard let fraction, fraction.isFinite else { return nil }
        return Int(min(100, max(0, fraction * 100)))
    }
    var progressText: String? {
        var pieces: [String] = []
        if let done = completedBytes {
            let current = ByteCountFormatter.string(fromByteCount: max(0, done), countStyle: .file)
            if let total = totalBytes, total > 0 {
                pieces.append(current + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
            } else { pieces.append(current) }
        }
        if let percentage { pieces.append("\(percentage)%") }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }
    var error = ""
    var collisionPolicy = CollisionPolicy.ask
    var conflicts: [String] = []
    var preferredHeight: CGFloat { state == .failed ? 90 : 44 }
    var attempt = 0
    var started = false
    var operation: BlockOperation?
    var openDestination: [String: Any]?
    var copiedPaths: [String] = []
    var clipboardPayload: ClipboardPayload?
    var opening = false
    init(target: [String: Any], paths: [String]) { self.target = target; self.paths = paths }
    var destination: String { destinationTitle(target) }
    var summary: String { paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) items" }
}
