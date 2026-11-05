import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-paste") || isProgressPreview() || CommandLine.arguments.contains("--render-preview")
    var panel: DropPanel!
    var statusItem: NSStatusItem!
    var icon: StatusDropView!
    let popover = NSPopover()
    let clickDismissal = PopoverClickDismissal()
    let quitButton = NSButton(title: "Quit Rex Drop", target: nil, action: nil)
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
            if isProgressPreview() { showProgress() } else { showDestinations(dragging: false) }
        } else {
            refresh()
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common); refreshTimer = timer
        }
        if CommandLine.arguments.contains("--smoke-test") { DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) } }
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
        clickDismissal.stop()
        statusItem?.button?.highlight(false)
        dismissWork?.cancel(); dismissWork = nil; drag.end(); popover.performClose(nil)
        if let pending = deferredTargets { deferredTargets = nil; applyTargets(pending) }
    }
    func popoverDidClose(_ notification: Notification) {
        clickDismissal.stop()
        statusItem?.button?.highlight(false)
        dismissWork?.cancel(); dismissWork = nil; drag.end()
        if let pending = deferredTargets { deferredTargets = nil; applyTargets(pending) }
    }
    func showDestinations(dragging: Bool) {
        guard let button = statusItem?.button else { return }
        button.highlight(true)
        for case let row as TargetRow in destinations.arrangedSubviews { row.updateClipboard() }
        dismissWork?.cancel(); dismissWork = nil
        popover.behavior = dragging ? .applicationDefined : .transient
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        clickDismissal.start(popover: popover, statusWindow: button.window) { [weak self] in self?.closeDestinations() }
        refresh()
    }
    func toggleDestinations() { if popover.isShown { closeDestinations() } else { showDestinations(dragging: false) } }
    func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        // The status button renders template images using the menu bar's own
        // contrast and highlight appearance; the overlay only receives input.
        let image = NSImage(systemSymbolName: "icloud.and.arrow.up.fill", accessibilityDescription: "Rex Drop — upload to server")!
        image.isTemplate = true
        button.image = image
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.imagePosition = .imageOnly
        button.toolTip = "Rex Drop · drag files here"
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
    func applicationWillTerminate(_ notification: Notification) {
        clickDismissal.stop()
        for task in tasks { task.clipboardPayload?.cleanup() }
    }
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
    func pasteClipboard(to target: [String: Any]) {
        guard !preview else { return }
        do {
            let payload = try ClipboardInput.capture(board: .general)
            transfer(target, paths: payload.paths, clipboardPayload: payload)
        } catch {
            closeDestinations()
            let alert = NSAlert(); alert.messageText = "Couldn’t paste"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    func transfer(_ target: [String: Any], paths: [String], clipboardPayload: ClipboardPayload? = nil) {
        guard canAcceptDrop, !paths.isEmpty else { return }
        closeDestinations()
        let task = TransferTask(target: target, paths: paths); tasks.append(task)
        task.clipboardPayload = clipboardPayload
        showProgress(); start(task, retry: false)
    }

}
