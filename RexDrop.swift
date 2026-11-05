import AppKit
import CoreGraphics

// Window-server coordinates use a top-left origin on the primary display.
func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> NSRect {
    NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}

struct DragGate {
    var baseline: Int
    var armed = false
    mutating func update(change: Int, pressed: Bool, hasFiles: Bool) -> Bool {
        guard pressed else { baseline = change; armed = false; return false }
        if change != baseline && hasFiles { armed = true }
        return armed && hasFiles
    }
}

func runUIStateTests() {
    let rect = appKitRect(CGRect(x: -1200, y: 100, width: 1000, height: 700), primaryTop: 900)
    precondition(rect == NSRect(x: -1200, y: 100, width: 1000, height: 700))
    let below = appKitRect(CGRect(x: 50, y: 950, width: 800, height: 600), primaryTop: 900)
    precondition(below.minY == -650)
    var gate = DragGate(baseline: 7)
    precondition(!gate.update(change: 7, pressed: true, hasFiles: true))
    precondition(gate.update(change: 8, pressed: true, hasFiles: true))
    precondition(gate.update(change: 8, pressed: true, hasFiles: true))
    precondition(!gate.update(change: 8, pressed: false, hasFiles: true))
    precondition(!gate.update(change: 8, pressed: true, hasFiles: true))
    precondition(!gate.update(change: 9, pressed: true, hasFiles: false))
    let ordered = orderedTargets([
        ["id": "local", "display_name": "Alpha", "kind": "local"],
        ["id": "ssh-z", "display_name": "Zulu", "kind": "ssh"],
        ["id": "ssh-a", "display_name": "alpha", "kind": "ssh"],
        ["id": "ssh-a", "display_name": "alpha", "kind": "ssh"],
        ["id": "unsupported", "kind": "unsupported"],
        ["id": "disabled", "kind": "local", "selectable": false]
    ])
    precondition(ordered.compactMap { $0["id"] as? String } == ["ssh-a", "ssh-z", "local"])
    precondition(TransferState.queued.active && TransferState.paused.active && TransferState.cancelling.active)
    precondition(!TransferState.complete.active && !TransferState.failed.active && !TransferState.cancelled.active)
    let task = TransferTask(target: ["display_name": "devbox"], paths: ["/tmp/example.txt"])
    precondition(task.summary == "example.txt" && task.destination == "devbox" && task.state == .queued)
    print("Rex Drop geometry, drag-state, destination ordering and task-state checks passed")


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
        let left = $0["display_name"] as? String ?? $0["label"] as? String ?? ""
        let right = $1["display_name"] as? String ?? $1["label"] as? String ?? ""
        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }
}

final class TargetRow: NSView {
    weak var owner: AppDelegate?
    let target: [String: Any]
    var hovering = false
    init(target: [String: Any], owner: AppDelegate) {
        self.target = target; self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL]); wantsLayer = true; layer?.cornerRadius = 10
        let ssh = (target["kind"] as? String) == "ssh"
        let icon = NSImageView(image: NSImage(systemSymbolName: ssh ? "network" : "folder", accessibilityDescription: ssh ? "SSH destination" : "Local destination")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: target["display_name"] as? String ?? target["label"] as? String ?? "Rex terminal")
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: target["detail"] as? String ?? (ssh ? "SSH" : "Local"))
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Drop to send")!)
        arrow.contentTintColor = .tertiaryLabelColor
        let content = NSStackView(views: [icon, labels, NSView(), arrow]); content.spacing = 13; content.alignment = .centerY
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 65), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), content.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 25), arrow.widthAnchor.constraint(equalToConstant: 15)])
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        detail.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        toolTip = "\(target["label"] as? String ?? title.stringValue)\n\(detail.stringValue)"
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
    func accepts(_ sender: NSDraggingInfo) -> Bool { owner?.canAcceptDrop == true && !files(sender.draggingPasteboard).isEmpty }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = accepts(sender)
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
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false; updateColor() }
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
    init(target: [String: Any], paths: [String]) { self.target = target; self.paths = paths }
    var destination: String { target["display_name"] as? String ?? target["label"] as? String ?? "Rex" }
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
    func update() {
        title.stringValue = (owner?.preview == true ? "Preview · " : "") + "\(task.summary) → \(task.destination)"
        let count = task.totalFiles > 0 ? " · \(task.completedFiles)/\(task.totalFiles)" : ""
        detail.stringValue = task.state == .running ? ((task.currentFile.isEmpty ? task.phase : task.currentFile) + count) : task.state.rawValue
        detail.textColor = task.state == .failed ? .systemOrange : task.state == .complete ? .systemGreen : .secondaryLabelColor
        toolTip = task.error.isEmpty ? task.paths.joined(separator: "\n") : task.error
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-progress") || CommandLine.arguments.contains("--render-preview")
    var panel: DropPanel!
    var statusItem: NSStatusItem!
    var automaticItem: NSMenuItem!
    let list = NSStackView()
    let scroll = NSScrollView()
    let result = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    var listHeight: NSLayoutConstraint!
    var tasks: [TransferTask] = []
    var cards: [UUID: TaskCard] = [:]
    var showingDestinations = true
    var autoList = false
    var headerView: NSView!
    var footerView: NSView!
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; return q }()
    var transferring: Bool { tasks.contains { $0.state.active } }
    var targets: [[String: Any]] = []

    var deferredTargets: [[String: Any]]?
    var refreshing = false, manual = false, automatic = true
    var timer: Timer?
    var lastRefresh = Date.distantPast
    var gate = DragGate(baseline: NSPasteboard(name: .drag).changeCount)
    var lastDrag = false
    var canAcceptDrop: Bool { !preview }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); makePanel()
        if preview { populatePreview() }
        makeMenu(); showManual()
        if CommandLine.arguments.contains("--smoke-test") { DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) } }
        if !preview { timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in self?.poll() } }
    }
    func exportPreview(_ path: String) throws {
        makePanel(); populatePreview()
        panel.orderFrontRegardless(); panel.contentView?.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DropFailure("Preview bitmap unavailable.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DropFailure("Preview PNG unavailable.") }
        try data.write(to: URL(fileURLWithPath: path))
    }
    func makePanel() {
        panel = DropPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 350), styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Rex Drop"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.delegate = self; panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root: NSView
        if preview {
            let plain = NSView(); plain.wantsLayer = true; plain.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; root = plain
        } else {
            let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active; root = effect
        }
        panel.contentView = root

        let title = NSTextField(labelWithString: preview ? "Rex Drop · Preview" : "Rex Drop"); title.font = .systemFont(ofSize: 19, weight: .semibold)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh destinations")!, target: self, action: #selector(refresh))
        refreshButton.isBordered = false; refreshButton.contentTintColor = .secondaryLabelColor; refreshButton.toolTip = "Refresh destinations"
        let header = NSStackView(views: [title, NSView(), progress, refreshButton]); header.spacing = 10
        headerView = header
        refreshButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 7
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        count.font = .systemFont(ofSize: 10); count.textColor = .tertiaryLabelColor
        result.font = .systemFont(ofSize: 11); result.textColor = .secondaryLabelColor; result.lineBreakMode = .byTruncatingTail
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [result, NSView(), count]); footer.spacing = 8
        footerView = footer
        let stack = NSStackView(views: [header, scroll, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setCustomSpacing(16, after: header)
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 170)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 43), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20), listHeight])
        for view in [header, scroll, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        showEmpty("Looking for your terminals…")
        panel.center()
    }
    func showEmpty(_ message: String) {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let label = NSTextField(wrappingLabelWithString: message); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
        label.alignment = .center; list.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        label.heightAnchor.constraint(equalToConstant: 90).isActive = true
    }
    func applyTargets(_ incoming: [[String: Any]]) {
        targets = orderedTargets(incoming)
        if showingDestinations { renderContent() }
    }
    func renderContent() {
        cards.removeAll()
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        headerView.isHidden = !showingDestinations; footerView.isHidden = !showingDestinations
        let height: Int
        if showingDestinations {
            if targets.isEmpty { showEmpty(refreshing ? "Looking for terminals…" : "No destinations") }
            for target in targets {
                let row = TargetRow(target: target, owner: self); list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            count.stringValue = "\(targets.count)"
            count.toolTip = "Available destinations"
            height = min(350, max(100, targets.count * 72 - 7))
        } else {
            for task in tasks {
                let card = TaskCard(task: task, owner: self); list.addArrangedSubview(card); cards[task.id] = card
                card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            height = min(430, max(91, tasks.count * 98 - 7))
        }
        listHeight.constant = CGFloat(height)
        let old = panel.frame, extra = showingDestinations ? 132 : 64
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - CGFloat(height + extra), width: old.width, height: CGFloat(height + extra)), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    func populatePreview() {
        applyTargets([
            ["id": "ssh-a", "display_name": "devbox", "kind": "ssh", "detail": "devbox:/tmp/rex-drop"],
            ["id": "ssh-b", "display_name": "staging", "kind": "ssh", "detail": "staging:/tmp/rex-drop"],
            ["id": "local-a", "display_name": "website", "kind": "local", "detail": "~/Projects/website"]
        ])
        if CommandLine.arguments.contains("--preview-progress") {
            let first = TransferTask(target: targets[0], paths: ["/example/design-assets"])
            first.state = .running; first.currentFile = "hero-image.png"; first.completedFiles = 3; first.totalFiles = 8
            let second = TransferTask(target: targets[1], paths: ["/example/notes.md"])
            second.state = .complete
            tasks = [first, second]; showingDestinations = false; renderContent()
        }
    }
    func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Rex Drop")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Drop Zone", action: #selector(showManual), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Targets", action: #selector(refresh), keyEquivalent: "r").target = self
        automaticItem = menu.addItem(withTitle: "Automatic Show", action: #selector(toggleAutomatic), keyEquivalent: "")
        automaticItem.target = self; automaticItem.state = .on
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Rex Drop", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }
    func windowWillClose(_ notification: Notification) { manual = false }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleAutomatic() { automatic.toggle(); automaticItem.state = automatic ? .on : .off }
    @objc func showManual() { manual = true; showingDestinations = !(preview && CommandLine.arguments.contains("--preview-progress")); renderContent(); panel.orderFrontRegardless(); refresh() }
    @objc func refresh() {
        guard !preview, !refreshing else { return }
        refreshing = true; lastRefresh = Date(); progress.startAnimation(nil)
        Backend.run("targets") { [weak self] response in
            guard let self else { return }; self.refreshing = false; self.progress.stopAnimation(nil)
            switch response {
            case .success(let json):
                if let error = json["error"] as? String { self.refreshFailed(error); return }
                let targets = json["targets"] as? [[String: Any]] ?? []
                // Existing drop rows remain stable for the entire gesture.
                if self.gate.armed && !self.targets.isEmpty { self.deferredTargets = targets }
                else { self.applyTargets(targets) }
            case .failure(let error): self.refreshFailed(error.localizedDescription)
            }
        }
    }
    func refreshFailed(_ message: String) {
        result.stringValue = "Couldn’t refresh destinations"; result.textColor = .systemOrange; result.toolTip = message
        // Cached snapshots stay usable; the backend revalidates the exact destination on drop.
        if targets.isEmpty && showingDestinations { showEmpty("No destinations") }
    }
    func transfer(_ target: [String: Any], paths: [String]) {
        guard canAcceptDrop, !paths.isEmpty else { return }
        let task = TransferTask(target: target, paths: paths)
        tasks.append(task); manual = true; showingDestinations = false; renderContent()
        start(task, retry: false)
    }
    func start(_ task: TransferTask, retry: Bool) {
        task.attempt += 1; let attempt = task.attempt
        task.control = DropTaskControl(); task.started = false; task.state = .queued; task.error = ""; task.fraction = nil
        task.currentFile = ""; task.completedFiles = 0; task.totalFiles = 0
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
    func rexWindow(at point: NSPoint) -> NSRect? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            let name = ($0.localizedName ?? "").lowercased()
            return name == "rex" || name == "rex beta" || ($0.bundleIdentifier ?? "").lowercased().hasSuffix(".rex")
        }
        let pids = Set(apps.map(\.processIdentifier))
        guard !pids.isEmpty, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != ProcessInfo.processInfo.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), bounds.width > 40, bounds.height > 40 else { continue }
            let rect = appKitRect(bounds, primaryTop: primary.frame.maxY)
            if rect.contains(point) { return pids.contains(pid) ? rect : nil }
        }
        return nil
    }
    func poll() {
        let board = NSPasteboard(name: .drag)
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let files = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let dragging = gate.update(change: board.changeCount, pressed: pressed, hasFiles: files)
        if automatic, dragging, (!panel.isVisible || !showingDestinations), let rex = rexWindow(at: NSEvent.mouseLocation) {
            showingDestinations = true; autoList = true; renderContent()
            // Reveal beside the pointer once. It remains still throughout the gesture.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
            var origin = NSPoint(x: mouse.x + 18, y: mouse.y - panel.frame.height + 46)
            if let visible = screen?.visibleFrame {
                let region = rex.intersection(visible)
                let bounds = region.width >= panel.frame.width && region.height >= panel.frame.height ? region : visible
                origin.x = max(bounds.minX, min(origin.x, bounds.maxX - panel.frame.width))
                origin.y = max(bounds.minY, min(origin.y, bounds.maxY - panel.frame.height))
            }
            panel.setFrameOrigin(origin); panel.orderFrontRegardless()
            if targets.isEmpty { refresh() }
        }
        if !pressed {
            if let targets = deferredTargets { deferredTargets = nil; applyTargets(targets) }
            if Date().timeIntervalSince(lastRefresh) > 5 { refresh() }
        }
        if lastDrag && !pressed && autoList {
            autoList = false
            if !tasks.isEmpty { showingDestinations = false; renderContent() }
            else if !manual { panel.orderOut(nil) }
        }

        lastDrag = dragging
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
