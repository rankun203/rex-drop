import AppKit

final class TaskCard: NSView {
    weak var owner: AppDelegate?
    let task: TransferTask
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let bar = NSProgressIndicator()
    let status = NSImageView()
    let progressLabel = NSTextField(labelWithString: "")
    let pause = NSButton(), cancel = NSButton()
    let keepBoth = NSButton(title: "Keep Both", target: nil, action: nil)
    let replace = NSButton(title: "Replace", target: nil, action: nil)
    var cardHeight: NSLayoutConstraint!
    init(task: TransferTask, owner: AppDelegate) {
        self.task = task; self.owner = owner; super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor; layer?.borderWidth = 0.5
        title.font = .systemFont(ofSize: 11, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11); detail.textColor = .systemOrange
        detail.maximumNumberOfLines = 3; detail.lineBreakMode = .byWordWrapping; detail.isSelectable = true
        bar.style = .bar; bar.controlSize = .small; bar.minValue = 0; bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: 40).isActive = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.widthAnchor.constraint(equalToConstant: 13).isActive = true
        status.heightAnchor.constraint(equalToConstant: 13).isActive = true
        for button in [pause, cancel] { button.isBordered = false; button.contentTintColor = .secondaryLabelColor; button.widthAnchor.constraint(equalToConstant: 19).isActive = true }
        for button in [keepBoth, replace] { button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 10) }
        keepBoth.target = self; keepBoth.action = #selector(keepAction); keepBoth.toolTip = "Keep all existing destination items; copy duplicates with numbered names"
        replace.target = self; replace.action = #selector(replaceAction); replace.toolTip = "Replace all matching destination files and whole folders"
        pause.target = self; pause.action = #selector(primaryAction); cancel.target = self; cancel.action = #selector(secondaryAction)
        let head = NSStackView(views: [title, NSView(), bar, progressLabel, status, pause, keepBoth, replace, cancel]); head.spacing = 5; head.alignment = .centerY
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [head, detail]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        cardHeight = heightAnchor.constraint(equalToConstant: task.preferredHeight)
        NSLayoutConstraint.activate([cardHeight, column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), column.centerYAnchor.constraint(equalTo: centerYAnchor)])
        for view in [head, detail] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, task.state == .complete, NSEvent.modifierFlags.contains(.command) else { return hit }
        var view = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }
    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command), bounds.contains(convert(event.locationInWindow, from: nil)) { owner?.openDestination(task) }
        else { super.mouseUp(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { task.state == .complete && event?.modifierFlags.contains(.command) == true }
    func update() {
        cardHeight.constant = task.preferredHeight
        title.stringValue = (owner?.preview == true ? "Preview · " : "") + "\(task.summary) → \(task.destination)"
        detail.isHidden = task.state != .failed
        detail.stringValue = task.error.isEmpty ? "Transfer failed." : task.error
        let count = task.totalFiles > 0 ? " · \(task.completedFiles)/\(task.totalFiles)" : ""
        let phase = task.currentFile.isEmpty ? task.phase : task.currentFile
        toolTip = task.paths.joined(separator: "\n") + "\n→ " + task.destination + "\n" + task.state.rawValue + " · " + phase + count
        if task.state == .conflict {
            toolTip = "Already exists:\n" + task.conflicts.joined(separator: "\n")
            if !task.error.isEmpty { toolTip = (toolTip ?? "") + "\n" + task.error }
        }
        if task.state == .failed { toolTip = task.error }
        if task.state == .complete { toolTip = (toolTip ?? "") + "\n⌘-click to open destination" }
        let showProgress = [.running, .queued, .paused].contains(task.state)
        progressLabel.stringValue = task.progressText ?? ""
        progressLabel.isHidden = !showProgress || task.progressText == nil
        bar.isHidden = ![.running, .queued].contains(task.state) || task.progressText != nil
        bar.isIndeterminate = task.state == .running && task.fraction == nil
        if bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil); bar.doubleValue = task.fraction ?? 0 }
        let symbol: String
        switch task.state {
        case .complete: symbol = "checkmark.circle.fill"
        case .failed: symbol = "exclamationmark.triangle.fill"
        case .conflict: symbol = "doc.on.doc"
        case .paused: symbol = "pause.circle"
        case .cancelled, .cancelling: symbol = "xmark.circle"
        default: symbol = "clock"
        }
        status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: task.state.rawValue)
        status.contentTintColor = task.state == .complete ? .systemGreen : task.state == .failed ? .systemOrange : .secondaryLabelColor
        status.isHidden = task.state == .running || task.state == .queued
        let retry = [.failed, .cancelled].contains(task.state), paused = task.state == .paused
        pause.isHidden = [.complete, .conflict, .cancelling].contains(task.state)
        pause.image = NSImage(systemSymbolName: retry ? "arrow.clockwise" : paused ? "play.fill" : "pause.fill", accessibilityDescription: retry ? "Retry" : paused ? "Resume" : "Pause")
        pause.toolTip = retry ? "Retry transfer" : paused ? "Resume transfer" : "Pause transfer"
        let canCancel = task.state.active || task.state == .conflict
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: canCancel ? "Cancel" : "Dismiss")
        cancel.toolTip = canCancel ? "Cancel transfer" : "Dismiss"
        keepBoth.isHidden = task.state != .conflict; replace.isHidden = task.state != .conflict
        for button in [pause, cancel, keepBoth, replace] { button.isEnabled = owner?.preview != true }
        cancel.isEnabled = task.state != .cancelling && owner?.preview != true
    }
    @objc func keepAction() { owner?.resolveConflict(task, policy: .keepBoth) }
    @objc func replaceAction() { owner?.resolveConflict(task, policy: .replace) }
    @objc func primaryAction() { owner?.primaryAction(task) }
    @objc func secondaryAction() { owner?.secondaryAction(task) }
}
