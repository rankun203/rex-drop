import AppKit

final class DestinationSurface: NSView {
    weak var owner: AppDelegate?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes(nativeFileTypes) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFiles(sender.draggingPasteboard) else { return [] }
        owner?.nativeDragEntered(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFiles(sender.draggingPasteboard) else { return [] }
        owner?.nativeDragEntered(); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.scheduleDragDismissal() }
    override func draggingEnded(_ sender: NSDraggingInfo) { owner?.scheduleDragDismissal() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { owner?.scheduleDragDismissal(); return false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func cancelOperation(_ sender: Any?) { owner?.closeDestinations() }
}
