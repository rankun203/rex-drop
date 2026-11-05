import AppKit

// LaunchServices starts this code in the desktop session, where running app
// identity and graceful termination requests reach the user's existing instance.
enum AppLifecycle {
    static func replaceRunning() -> Bool {
        let application = NSApplication.shared
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.pathExtension == "app" else {
            fputs("Run launch.sh from the built project.\n", stderr)
            return false
        }
        let current = ProcessInfo.processInfo.processIdentifier
        let previous = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != current, let url = app.bundleURL else { return false }
            return url.resolvingSymlinksInPath().standardizedFileURL == bundle
        }
        for app in previous { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while previous.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard previous.allSatisfy({ $0.isTerminated }) else {
            application.setActivationPolicy(.accessory)
            application.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Rex Drop is busy"
            alert.informativeText = "Finish or cancel its transfers, then run launch.sh again. The current app will keep running."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        return true
    }
}
