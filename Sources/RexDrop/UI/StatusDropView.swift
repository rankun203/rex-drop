import AppKit

// All drag state comes from AppKit destination callbacks on our own views.
final class StatusDropView: NSView {
    weak var owner: AppDelegate?
    override init(frame: NSRect) {
        super.init(frame: frame); registerForDraggedTypes(nativeFileTypes)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Rex Drop")
    }

    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityPerformPress() -> Bool { owner?.toggleDestinations(); return owner != nil }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { owner?.showCommands(event) }
        else { owner?.toggleDestinations() }
    }
    override func rightMouseDown(with event: NSEvent) { owner?.showCommands(event) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFiles(sender.draggingPasteboard) else { return [] }
        owner?.nativeDragEntered(); owner?.showDestinations(dragging: true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFiles(sender.draggingPasteboard) else { return [] }
        owner?.nativeDragEntered(); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.scheduleDragDismissal() }
    override func draggingEnded(_ sender: NSDraggingInfo) { owner?.scheduleDragDismissal() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { owner?.scheduleDragDismissal(); return false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
