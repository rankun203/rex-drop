import AppKit

final class TargetRow: NSView {
    weak var owner: AppDelegate?
    let target: [String: Any]
    var hovering = false
    var pressed = false
    let pasteButton = NSButton()
    let title = NSTextField(labelWithString: "")
    let openIcon = NSImageView()
    private let clipboardAvailability: Bool?
    init(target: [String: Any], owner: AppDelegate, clipboardAvailable: Bool? = nil) {
        self.target = target; self.owner = owner; self.clipboardAvailability = clipboardAvailable
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(destinationTitle(target))
        registerForDraggedTypes(nativeFileTypes); wantsLayer = true; layer?.cornerRadius = 10
        let ssh = (target["kind"] as? String) == "ssh"
        let icon = NSImageView(image: NSImage(systemSymbolName: ssh ? "network" : "folder", accessibilityDescription: ssh ? "SSH destination" : "Local destination")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.stringValue = destinationTitle(target)
        title.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle; title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: ssh ? "Private folder · SSH" : "Local folder")
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail; detail.maximumNumberOfLines = 1
        openIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open destination")
        openIcon.contentTintColor = .tertiaryLabelColor; openIcon.toolTip = "Open destination"
        pasteButton.title = ""
        pasteButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste clipboard")
        pasteButton.isBordered = false; pasteButton.imagePosition = .imageOnly
        pasteButton.contentTintColor = .secondaryLabelColor
        pasteButton.target = self; pasteButton.action = #selector(pasteClipboard)
        pasteButton.setAccessibilityLabel("Paste clipboard")
        pasteButton.toolTip = "Paste clipboard files or image to " + destinationTitle(target)
        // Fixed controls reserve their space; a long path only compresses its label.
        for view in [icon, title, detail, pasteButton, openIcon] {
            addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 65),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 24),
            openIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            openIcon.centerYAnchor.constraint(equalTo: centerYAnchor), openIcon.widthAnchor.constraint(equalToConstant: 17),
            pasteButton.trailingAnchor.constraint(equalTo: openIcon.leadingAnchor, constant: -10),
            pasteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pasteButton.widthAnchor.constraint(equalToConstant: 22), pasteButton.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)
        ])
        toolTip = "\(title.stringValue)\n\(target["label"] as? String ?? "")\n\(target["detail"] as? String ?? detail.stringValue)"
        updateColor()
        updateClipboard()
    }
    func updateClipboard() {
        // Keep the action available so unsupported content gets paste feedback
        // instead of letting the click reach the destination row.
        pasteButton.isEnabled = owner?.preview != true
        let available = clipboardAvailability ?? ClipboardInput.canPaste(board: .general)
        pasteButton.contentTintColor = available ? .secondaryLabelColor : .tertiaryLabelColor
    }
    @objc func pasteClipboard() { owner?.pasteClipboard(to: target) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else { return nil }
        var view = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let shouldOpen = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if shouldOpen { owner?.openTarget(target) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard owner?.preview == false else { return false }
        owner?.openTarget(target); return true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    func updateColor() {
        layer?.backgroundColor = (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.025)).cgColor
        layer?.borderColor = (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.7) : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor
        layer?.borderWidth = hovering ? 1 : 0.5
    }
    func files(_ board: NSPasteboard) -> [String] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(\.isFileURL).map(\.path)
    }
    func accepts(_ sender: NSDraggingInfo) -> Bool { acceptsTransfer(.destination, fileCount: files(sender.draggingPasteboard).count, preview: owner?.preview ?? true) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = accepts(sender)
        if valid { owner?.nativeDragEntered() }
        if hovering != valid {
            hovering = valid; updateColor()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.7; fade.toValue = 1; fade.duration = 0.14
                layer?.add(fade, forKey: "hover")
            }
        }
        return valid ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false; updateColor(); owner?.scheduleDragDismissal() }
    override func draggingEnded(_ sender: NSDraggingInfo) { owner?.scheduleDragDismissal() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        let paths = files(sender.draggingPasteboard)
        hovering = false; updateColor()
        owner?.transfer(target, paths: paths)
        return true
    }
}
