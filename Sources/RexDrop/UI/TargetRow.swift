import AppKit

final class TargetRow: NSView {
    weak var owner: AppDelegate?
    let target: [String: Any]
    var hovering = false
    let pasteButton = NSButton(title: "Paste", target: nil, action: nil)
    init(target: [String: Any], owner: AppDelegate) {
        self.target = target; self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes(nativeFileTypes); wantsLayer = true; layer?.cornerRadius = 10
        let ssh = (target["kind"] as? String) == "ssh"
        let icon = NSImageView(image: NSImage(systemSymbolName: ssh ? "network" : "folder", accessibilityDescription: ssh ? "SSH destination" : "Local destination")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: destinationTitle(target))
        title.font = .monospacedSystemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: ssh ? "Private folder · SSH" : "Local folder")
        detail.font = .systemFont(ofSize: 10, weight: .regular); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Drop to send")!)
        arrow.contentTintColor = .tertiaryLabelColor
        pasteButton.bezelStyle = .rounded; pasteButton.controlSize = .small
        pasteButton.target = self; pasteButton.action = #selector(pasteClipboard)
        pasteButton.toolTip = "Paste clipboard files or image to " + destinationTitle(target)
        let content = NSStackView(views: [icon, labels, NSView(), pasteButton, arrow]); content.spacing = 13; content.alignment = .centerY
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 65), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), content.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 25), arrow.widthAnchor.constraint(equalToConstant: 15)])
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        detail.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        toolTip = "\(title.stringValue)\n\(target["label"] as? String ?? "")\n\(target["detail"] as? String ?? detail.stringValue)"
        updateColor()
        updateClipboard()
    }
    func updateClipboard() {
        pasteButton.isHidden = owner?.preview == true ? !CommandLine.arguments.contains("--preview-paste") : !ClipboardInput.canPaste(board: .general)
        pasteButton.isEnabled = owner?.preview != true
    }
    @objc func pasteClipboard() { owner?.pasteClipboard(to: target) }
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
