import AppKit

extension AppDelegate {
    func openTarget(_ target: [String: Any]) {
        guard !preview else { return }
        closeDestinations()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = DropService()
                let destination = try service.destinationToOpen(target)
                if destination["kind"] as? String == "local", let directory = destination["directory"] as? String {
                    DispatchQueue.main.async {
                        if !NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true)) {
                            Self.showOpenError("Finder could not open this folder.")
                        }
                    }
                } else {
                    try service.openRemoteDestination(destination)
                    DispatchQueue.main.async {
                        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.superlogical.rex" }?.activate(options: [])
                    }
                }
            } catch {
                DispatchQueue.main.async { Self.showOpenError(error.localizedDescription) }
            }
        }
    }

    private static func showOpenError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Couldn’t open destination"
        alert.informativeText = message; alert.runModal()
    }
}
