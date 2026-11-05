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
