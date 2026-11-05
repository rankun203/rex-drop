import AppKit

func isProgressPreview() -> Bool { ["--preview-progress", "--preview-conflict", "--preview-error"].contains(where: CommandLine.arguments.contains) }

extension AppDelegate {
    func populatePreview() {
        applyTargets([
            ["id": "ssh-a", "display_name": "dev@devbox", "destination_display": "dev@devbox:/tmp", "kind": "ssh"],
            ["id": "ssh-b", "display_name": "dev@staging", "destination_display": "dev@staging:/tmp", "kind": "ssh"],
            ["id": "local-a", "display_name": "website", "destination_display": "~/Projects/website", "kind": "local"]
        ])
        if CommandLine.arguments.contains("--preview-long-paths") {
            applyTargets([
                ["id": "long-ssh", "kind": "ssh", "destination_display": "developer@development-cluster.production.example.test:2222:/tmp"],
                ["id": "long-local", "kind": "local", "destination_display": "~/Projects/client-work/very-long-project-name/design/assets/production"]
            ])
        }
        if isProgressPreview() {

            let first = TransferTask(target: targets[0], paths: ["/example/design-assets"])
            first.state = .running; first.currentFile = "hero-image.png"; first.completedFiles = 3; first.totalFiles = 8
            first.completedBytes = 12_000_000; first.totalBytes = 40_000_000; first.fraction = 0.3
            let second = TransferTask(target: targets[1], paths: ["/example/notes.md"]); second.state = .complete
            tasks = [first, second]
            if CommandLine.arguments.contains("--preview-conflict") {
                let conflict = TransferTask(target: targets.last!, paths: ["/example/logo.svg"])
                conflict.state = .conflict; conflict.conflicts = ["~/Projects/website/logo.svg"]
                tasks = [conflict]
            }
            if CommandLine.arguments.contains("--preview-error") {
                first.state = .failed; first.error = "Permission denied while copying assets/logo.svg."
                tasks = [first]
            }
            renderContent()
        }
    }
    func exportPreview(_ path: String) throws {
        makePanel(); makePopover(); populatePreview()
        let view: NSView
        let host: NSPanel
        if isProgressPreview() { host = panel; view = panel.contentView! }
        else {
            view = popover.contentViewController!.view
            host = NSPanel(contentRect: NSRect(origin: .zero, size: popover.contentSize), styleMask: .borderless, backing: .buffered, defer: false)
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; host.contentView = view
        }
        // A headless renderer has no screen to constrain a resizable window to.
        if !NSScreen.screens.isEmpty { host.orderFrontRegardless() }
        view.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DropFailure("Preview bitmap unavailable.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DropFailure("Preview PNG unavailable.") }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
