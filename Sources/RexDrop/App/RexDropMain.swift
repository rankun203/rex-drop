import AppKit

@main
struct RexDropMain {
    static func main() {
        // Preview mode stays fully isolated from live terminals, including CLI flags.
        let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-paste") || isProgressPreview() || CommandLine.arguments.contains("--render-preview")
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
