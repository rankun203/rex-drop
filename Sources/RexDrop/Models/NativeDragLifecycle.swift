import AppKit

enum DropRoute { case icon, background, destination }
func acceptsTransfer(_ route: DropRoute, fileCount: Int, preview: Bool) -> Bool {
    route == .destination && fileCount > 0 && !preview
}
struct NativeDragLifecycle {
    private(set) var generation = 0
    private(set) var active = false
    mutating func enter() { generation += 1; active = true }
    mutating func end() { generation += 1; active = false }
    func mayDismiss(_ token: Int) -> Bool { active && token == generation }
}
