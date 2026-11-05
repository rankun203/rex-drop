import AppKit

let nativeFileTypes: [NSPasteboard.PasteboardType] = [.fileURL]

// All drag state comes from AppKit destination callbacks on our own views.
final class StatusDropView: NSView {
    weak var owner: AppDelegate?
        override init(frame: NSRect) {
        super.init(frame: frame); registerForDraggedTypes(nativeFileTypes)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Rex Drop")
    }

    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Rex Drop")!
        image.isTemplate = true
        image.draw(in: NSRect(x: (bounds.width - 17) / 2, y: (bounds.height - 18) / 2, width: 17, height: 18))
    }
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
func containsFiles(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
}
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
func runUIStateTests() {
    precondition(nativeFileTypes == [.fileURL])
    precondition(!acceptsTransfer(.icon, fileCount: 1, preview: false))
    precondition(!acceptsTransfer(.background, fileCount: 1, preview: false))
    precondition(acceptsTransfer(.destination, fileCount: 2, preview: false))
    precondition(!acceptsTransfer(.destination, fileCount: 0, preview: false))
    precondition(!acceptsTransfer(.destination, fileCount: 1, preview: true))
    var drag = NativeDragLifecycle()
    drag.enter(); let iconExit = drag.generation
    precondition(drag.mayDismiss(iconExit))
    drag.enter() // Entering the popover cancels the icon's pending exit.
    precondition(!drag.mayDismiss(iconExit))
    let rowExit = drag.generation
    precondition(drag.mayDismiss(rowExit))
    drag.end(); precondition(!drag.mayDismiss(rowExit))
    let sorted = orderedTargets([
        ["id": "local", "kind": "local", "destination_display": "~/site"],
        ["id": "ssh-z", "kind": "ssh", "destination_display": "dev@zulu:/tmp"],
        ["id": "ssh-a", "kind": "ssh", "destination_display": "dev@alpha:/tmp"],
        ["id": "ssh-a", "kind": "ssh", "destination_display": "dev@alpha:/tmp"],
        ["id": "disabled", "kind": "local", "selectable": false]
    ])
    precondition(sorted.compactMap { $0["id"] as? String } == ["ssh-a", "ssh-z", "local"])
    precondition(destinationTitle(["kind": "ssh", "display_name": "dev@host"]) == "dev@host:/tmp")
    precondition(TransferState.paused.active && TransferState.cancelling.active && !TransferState.complete.active)
    print("Rex Drop native drop-routing, drag-lifecycle, ordering and task-state checks passed")
    exit(0)
}

struct Backend {
    static func run(_ command: String, payload: [String: Any]? = nil,
                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: [String: Any]
                if command == "targets" { result = ["targets": try DropBackend.targets()] }
                else { result = try DropBackend.transfer(payload ?? [:]) }
                DispatchQueue.main.async { completion(.success(result)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

func orderedTargets(_ targets: [[String: Any]]) -> [[String: Any]] {
    var seen = Set<String>()
    return targets.filter {
        guard ($0["selectable"] as? Bool) != false, ($0["kind"] as? String) != "unsupported", let id = $0["id"] as? String else { return false }
        return seen.insert(id).inserted
    }.sorted {
        let leftSSH = ($0["kind"] as? String) == "ssh", rightSSH = ($1["kind"] as? String) == "ssh"
        if leftSSH != rightSSH { return leftSSH }
        let left = destinationTitle($0)
        let right = destinationTitle($1)
        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }
}

func destinationTitle(_ target: [String: Any]) -> String {
    if let display = target["destination_display"] as? String, !display.isEmpty { return display }
    if target["kind"] as? String == "ssh" {
        return (target["display_name"] as? String ?? "SSH") + ":/tmp"
    }
    let detail = target["detail"] as? String ?? ""
    let path = target["destination_path"] as? String ?? detail.components(separatedBy: " · ").last ?? ""
    if path.hasPrefix("/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    return path.isEmpty ? (target["display_name"] as? String ?? target["label"] as? String ?? "Rex") : path
}

final class TargetRow: NSView {
    weak var owner: AppDelegate?
    let target: [String: Any]
    var hovering = false
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
        let content = NSStackView(views: [icon, labels, NSView(), arrow]); content.spacing = 13; content.alignment = .centerY
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 65), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), content.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 25), arrow.widthAnchor.constraint(equalToConstant: 15)])
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        detail.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        toolTip = "\(title.stringValue)\n\(target["label"] as? String ?? "")\n\(target["detail"] as? String ?? detail.stringValue)"
        updateColor()
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

enum TransferState: String {
    case queued = "Queued", running = "Sending", paused = "Paused", cancelling = "Cancelling", cancelled = "Cancelled", failed = "Failed", complete = "Complete"
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
    var attempt = 0
    var started = false
    var operation: BlockOperation?
    var openDestination: [String: Any]?
    var copiedPaths: [String] = []
    var opening = false
    init(target: [String: Any], paths: [String]) { self.target = target; self.paths = paths }
    var destination: String { destinationTitle(target) }
    var summary: String { paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) items" }
}
final class TaskCard: NSView {
    weak var owner: AppDelegate?
    let task: TransferTask
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let pause = NSButton(), cancel = NSButton()
    init(task: TransferTask, owner: AppDelegate) {
        self.task = task; self.owner = owner; super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor; layer?.borderWidth = 0.5
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar; bar.controlSize = .small; bar.minValue = 0; bar.maxValue = 1
        for button in [pause, cancel] { button.isBordered = false; button.contentTintColor = .secondaryLabelColor; button.widthAnchor.constraint(equalToConstant: 22).isActive = true }
        pause.target = self; pause.action = #selector(primaryAction); cancel.target = self; cancel.action = #selector(secondaryAction)
        let head = NSStackView(views: [title, NSView(), pause, cancel]); head.spacing = 5
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [head, detail, bar]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 7
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 91), column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), column.centerYAnchor.constraint(equalTo: centerYAnchor)])
        for view in [head, detail, bar] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, task.state == .complete, NSEvent.modifierFlags.contains(.command) else { return hit }
        // Keep task controls independent from the card's destination shortcut.
        var view = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }
    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command), bounds.contains(convert(event.locationInWindow, from: nil)) {
            owner?.openDestination(task)
        } else { super.mouseUp(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        task.state == .complete && event?.modifierFlags.contains(.command) == true
    }
    func update() {
        title.stringValue = (owner?.preview == true ? "Preview · " : "") + "\(task.summary) → \(task.destination)"
        let count = task.totalFiles > 0 ? " · \(task.completedFiles)/\(task.totalFiles)" : ""
        detail.stringValue = task.state == .running ? ((task.currentFile.isEmpty ? task.phase : task.currentFile) + count) : task.state.rawValue
        detail.textColor = task.state == .failed ? .systemOrange : task.state == .complete ? .systemGreen : .secondaryLabelColor
        toolTip = task.error.isEmpty ? task.paths.joined(separator: "\n") + "\n→ " + task.destination : task.error
        if task.state == .complete { toolTip = (toolTip ?? "") + "\n⌘-click to open destination" }
        let spinning = task.state == .running && task.fraction == nil
        bar.isIndeterminate = spinning
        if spinning { bar.startAnimation(nil) } else { bar.stopAnimation(nil); bar.doubleValue = task.state == .complete ? 1 : (task.fraction ?? 0) }
        bar.alphaValue = task.state == .paused ? 0.4 : 1
        let retry = [.failed, .cancelled].contains(task.state)
        let paused = task.state == .paused
        pause.isHidden = [.complete, .cancelling].contains(task.state)
        pause.image = NSImage(systemSymbolName: retry ? "arrow.clockwise" : paused ? "play.fill" : "pause.fill", accessibilityDescription: retry ? "Retry" : paused ? "Resume" : "Pause")
        pause.toolTip = retry ? "Retry transfer" : paused ? "Resume transfer" : "Pause transfer"
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: task.state.active ? "Cancel" : "Dismiss")
        cancel.toolTip = task.state.active ? "Cancel transfer" : "Dismiss"
        pause.isEnabled = owner?.preview != true
        cancel.isEnabled = task.state != .cancelling && owner?.preview != true
    }
    @objc func primaryAction() { owner?.primaryAction(task) }
    @objc func secondaryAction() { owner?.secondaryAction(task) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-progress") || CommandLine.arguments.contains("--render-preview")
    var panel: DropPanel!
    var statusItem: NSStatusItem!
    var icon: StatusDropView!
    let popover = NSPopover()
    let destinations = NSStackView(), list = NSStackView()
    let destinationScroll = NSScrollView(), scroll = NSScrollView()
    var destinationHeight: NSLayoutConstraint!, listHeight: NSLayoutConstraint!
    var tasks: [TransferTask] = []
    var cards: [UUID: TaskCard] = [:]
    var targets: [[String: Any]] = []
    var deferredTargets: [[String: Any]]?
    var refreshing = false
    var drag = NativeDragLifecycle()
    var dragActive: Bool { drag.active }
    var dismissWork: DispatchWorkItem?
    var refreshTimer: Timer?
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; return q }()
    var transferring: Bool { tasks.contains { $0.state.active } }
    var canAcceptDrop: Bool { !preview }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel(); makePopover(); makeMenu()
        if preview {
            populatePreview()
            if CommandLine.arguments.contains("--preview-progress") { showProgress() } else { showDestinations(dragging: false) }
        } else {
            refresh()
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common); refreshTimer = timer
        }
        if CommandLine.arguments.contains("--smoke-test") { DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) } }
    }
    func installScroll(_ scroll: NSScrollView, stack: NSStackView, in root: NSView, inset: CGFloat) -> NSLayoutConstraint {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = stack
        root.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        let height = scroll.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset), scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: inset), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset), height, stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return height
    }
    func makePanel() {
        panel = DropPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 155), styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Rex Drop"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.delegate = self; panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root: NSView
        if preview { let plain = NSView(); plain.wantsLayer = true; plain.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; root = plain }
        else { let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active; root = effect }
        panel.contentView = root
        let container = NSView(); root.addSubview(container); container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), container.topAnchor.constraint(equalTo: root.topAnchor, constant: 34), container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
        listHeight = installScroll(scroll, stack: list, in: container, inset: 0)
        panel.center()
    }
    func makePopover() {
        let controller = NSViewController(), root = DestinationSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 116))
        root.owner = self; controller.view = root
        destinationHeight = installScroll(destinationScroll, stack: destinations, in: root, inset: 10)
        popover.contentViewController = controller; popover.delegate = self
        popover.behavior = .applicationDefined; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        renderDestinations()
    }
    func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    func renderDestinations() {
        clear(destinations)
        if targets.isEmpty {
            let empty = NSTextField(labelWithString: refreshing ? "Loading…" : "No destinations")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor; empty.alignment = .center
            destinations.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: destinations.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 70).isActive = true
        }
        for target in targets {
            let row = TargetRow(target: target, owner: self); destinations.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: destinations.widthAnchor).isActive = true
        }
        let height = CGFloat(min(455, max(70, targets.count * 72 - 7)))
        destinationHeight.constant = height; popover.contentSize = NSSize(width: 400, height: height + 20)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
    }
    func renderContent() {
        clear(list); cards.removeAll()
        for task in tasks {
            let card = TaskCard(task: task, owner: self); list.addArrangedSubview(card); cards[task.id] = card
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let height = CGFloat(min(430, max(91, tasks.count * 98 - 7)))
        listHeight.constant = height
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - height - 46, width: old.width, height: height + 46), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    func applyTargets(_ incoming: [[String: Any]]) { targets = orderedTargets(incoming); renderDestinations() }
    func nativeDragEntered() { dismissWork?.cancel(); dismissWork = nil; drag.enter(); popover.behavior = .applicationDefined }
    func scheduleDragDismissal() {
        dismissWork?.cancel()
        let token = drag.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag.mayDismiss(token) else { return }
            self.closeDestinations()
        }
        dismissWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }
    func closeDestinations() {
        dismissWork?.cancel(); dismissWork = nil; drag.end(); popover.performClose(nil)
        if let pending = deferredTargets { deferredTargets = nil; applyTargets(pending) }
    }
    func popoverDidClose(_ notification: Notification) {
        dismissWork?.cancel(); dismissWork = nil; drag.end()
        if let pending = deferredTargets { deferredTargets = nil; applyTargets(pending) }
    }
    func showDestinations(dragging: Bool) {
        guard let button = statusItem?.button else { return }
        dismissWork?.cancel(); dismissWork = nil
        popover.behavior = dragging ? .applicationDefined : .transient
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        if targets.isEmpty { refresh() }
    }
    func toggleDestinations() { if popover.isShown { closeDestinations() } else { showDestinations(dragging: false) } }
    func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = nil; button.toolTip = "Rex Drop · drag files here"
        icon = StatusDropView(frame: button.bounds); icon.owner = self; icon.autoresizingMask = [.width, .height]; button.addSubview(icon)
    }
    func showCommands(_ event: NSEvent) {
        closeDestinations()
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Progress", action: #selector(showProgress), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Destinations", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Rex Drop", action: #selector(quit), keyEquivalent: "q").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: icon)
    }
    @objc func showProgress() { guard !tasks.isEmpty else { return }; renderContent(); panel.orderFrontRegardless() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { transferring ? .terminateCancel : .terminateNow }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func refresh() {
        guard !preview, !refreshing else { return }
        refreshing = true
        if targets.isEmpty { renderDestinations() }
        Backend.run("targets") { [weak self] response in
            guard let self else { return }; self.refreshing = false
            switch response {
            case .success(let json):
                if let error = json["error"] as? String { self.refreshFailed(error); return }
                let targets = json["targets"] as? [[String: Any]] ?? []
                if self.dragActive && !self.targets.isEmpty { self.deferredTargets = targets }
                else { self.applyTargets(targets) }
            case .failure(let error): self.refreshFailed(error.localizedDescription)
            }
        }
    }
    func refreshFailed(_ message: String) {
        if targets.isEmpty { renderDestinations(); popover.contentViewController?.view.toolTip = message }
    }
    func transfer(_ target: [String: Any], paths: [String]) {
        guard canAcceptDrop, !paths.isEmpty else { return }
        closeDestinations()
        let task = TransferTask(target: target, paths: paths); tasks.append(task)
        showProgress(); start(task, retry: false)
    }
    func populatePreview() {
        applyTargets([
            ["id": "ssh-a", "display_name": "dev@devbox", "destination_display": "dev@devbox:/tmp", "kind": "ssh"],
            ["id": "ssh-b", "display_name": "dev@staging", "destination_display": "dev@staging:/tmp", "kind": "ssh"],
            ["id": "local-a", "display_name": "website", "destination_display": "~/Projects/website", "kind": "local"]
        ])
        if CommandLine.arguments.contains("--preview-progress") {
            let first = TransferTask(target: targets[0], paths: ["/example/design-assets"])
            first.state = .running; first.currentFile = "hero-image.png"; first.completedFiles = 3; first.totalFiles = 8
            let second = TransferTask(target: targets[1], paths: ["/example/notes.md"]); second.state = .complete
            tasks = [first, second]; renderContent()
        }
    }
    func exportPreview(_ path: String) throws {
        makePanel(); makePopover(); populatePreview()
        let view: NSView
        let host: NSPanel
        if CommandLine.arguments.contains("--preview-progress") { host = panel; view = panel.contentView! }
        else {
            view = popover.contentViewController!.view
            host = NSPanel(contentRect: NSRect(origin: .zero, size: popover.contentSize), styleMask: .borderless, backing: .buffered, defer: false)
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; host.contentView = view
        }
        host.orderFrontRegardless(); view.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DropFailure("Preview bitmap unavailable.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DropFailure("Preview PNG unavailable.") }
        try data.write(to: URL(fileURLWithPath: path))
    }
    func start(_ task: TransferTask, retry: Bool) {
        task.attempt += 1; let attempt = task.attempt
        task.control = DropTaskControl(); task.started = false; task.state = .queued; task.error = ""; task.fraction = nil
        task.currentFile = ""; task.completedFiles = 0; task.totalFiles = 0
        task.openDestination = nil; task.copiedPaths = []
        updateTask(task)
        let control = task.control, original = task.target, paths = task.paths
        let operation = BlockOperation { [weak self, weak task] in
            guard let task else { return }
            do {
                var target = original
                if retry {
                    let latest = try DropBackend.targets()
                    guard let key = original["destination_key"] as? String,
                          let current = latest.first(where: { ($0["destination_key"] as? String) == key && ($0["selectable"] as? Bool) != false && ($0["kind"] as? String) != "unsupported" }) else {
                        throw DropFailure("Destination unavailable. Refresh destinations and drop again.")
                    }
                    target = current
                }
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.started = true
                    task.target = target
                    if task.state == .queued { task.state = .running }
                    self?.updateTask(task)
                }
                let service = DropService(control: control, progress: { progress in
                    DispatchQueue.main.async {
                        guard task.attempt == attempt, task.state.active else { return }
                        task.phase = progress.phase; task.currentFile = progress.currentFile
                        task.completedFiles = progress.completedFiles; task.totalFiles = progress.totalFiles; task.fraction = progress.fraction
                        self?.updateTask(task)
                    }
                })
                let response = try service.transfer(["target": target, "paths": paths])
                guard response["ok"] as? Bool == true else { throw DropFailure(response["error"] as? String ?? "Transfer failed.") }
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.openDestination = response["open_destination"] as? [String: Any]
                    task.copiedPaths = response["paths"] as? [String] ?? []
                    task.state = .complete; self?.updateTask(task)
                }
            } catch {
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.state = control.isCancelled ? .cancelled : .failed
                    task.error = error.localizedDescription; self?.updateTask(task)
                }
            }
        }
        task.operation = operation
        queue.addOperation(operation)
    }
    func updateTask(_ task: TransferTask) { cards[task.id]?.update() }
    func openDestination(_ task: TransferTask) {
        guard !preview, task.state == .complete, !task.opening else { return }
        if task.target["kind"] as? String == "local" {
            guard !task.copiedPaths.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(task.copiedPaths.map { URL(fileURLWithPath: $0) })
            return
        }
        guard let destination = task.openDestination else { return }
        task.opening = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try DropService().openRemoteDestination(destination)
                DispatchQueue.main.async {
                    task.opening = false; task.error = ""; self?.updateTask(task)
                    let rex = NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == "com.superlogical.rex"
                    }
                    rex?.activate(options: [])
                }
            } catch {
                DispatchQueue.main.async {
                    task.opening = false; task.error = error.localizedDescription; self?.updateTask(task)
                    let alert = NSAlert(); alert.messageText = "Couldn’t open destination"
                    alert.informativeText = error.localizedDescription
                    if let panel = self?.panel { alert.beginSheetModal(for: panel) }
                }
            }
        }
    }
    func primaryAction(_ task: TransferTask) {
        switch task.state {
        case .queued, .running: task.control.pause(); task.state = .paused
        case .paused: task.control.resume(); task.state = task.started ? .running : .queued
        case .failed, .cancelled: start(task, retry: true)
        default: break
        }
        updateTask(task)
    }
    func secondaryAction(_ task: TransferTask) {
        if task.state.active {
            task.control.cancel()
            if task.started { task.state = .cancelling }
            else { task.operation?.cancel(); task.state = .cancelled }
            updateTask(task)
        } else {
            tasks.removeAll { $0.id == task.id }; cards.removeValue(forKey: task.id)
            if tasks.isEmpty { panel.orderOut(nil) }
            else { renderContent() }
        }
    }

}

@main
struct RexDropMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { runUIStateTests() }
        // Preview mode stays fully isolated from live terminals, including CLI flags.
        let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-progress") || CommandLine.arguments.contains("--render-preview")
        if !preview && (CommandLine.arguments.contains("--targets") || CommandLine.arguments.contains("--transfer")) {
            let response: [String: Any]
            var status: Int32 = 0
            do {
                if CommandLine.arguments.contains("--targets") {
                    response = ["targets": try DropBackend.targets()]
                } else {
                    let data = FileHandle.standardInput.readDataToEndOfFile()
                    let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    response = try DropBackend.transfer(request)
                }
            } catch { response = ["ok": false, "error": error.localizedDescription]; status = 1 }
            if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data); print("")
            }
            exit(status)
        }
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--replace-running"), !AppLifecycle.replaceRunning() { exit(1) }
        let delegate = AppDelegate()
        if let argument = CommandLine.arguments.firstIndex(of: "--render-preview") {
            do {
                guard CommandLine.arguments.count > argument + 1 else { throw DropFailure("Missing preview output path.") }
                try delegate.exportPreview(CommandLine.arguments[argument + 1])
            } catch { fputs("Preview export failed: \(error.localizedDescription)\n", stderr); exit(1) }
            exit(0)
        }
        application.delegate = delegate

        withExtendedLifetime(delegate) { application.run() }
    }
}
