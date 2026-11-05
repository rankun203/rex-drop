import AppKit

/// Native button tracking owns press/release and cancellation; the background
/// adds a quiet hover affordance without changing the resting icon.
final class IconButton: NSButton {
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""; isBordered = false; imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovering || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.18 : 0.08).setFill()
            // AppKit's button alignment insets can make its drawing bounds taller
            // than its layout size. Center a square independently of those bounds.
            let side = min(26, min(bounds.width, bounds.height) - 2)
            let square = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            NSBezierPath(roundedRect: square, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
