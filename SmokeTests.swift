import Foundation

// Opt-in integration check: create one disposable Rex shell and clean it up.
@main
struct SmokeTests {
    static func command(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("REX") }
        let output = Pipe(), incoming = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.standardInput = incoming
        try process.run()
        if let input { incoming.fileHandleForWriting.write(input) }
        try incoming.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Command failed: \(URL(fileURLWithPath: executable).lastPathComponent)") }
        return data
    }
    static func failure(_ text: String) -> NSError {
        NSError(domain: "RexDropSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid JSON") }
        return value
    }
    static func check() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("Pass the built RexDrop executable path") }
        let app = CommandLine.arguments[1]
        // Exercise real process inspection while a local ProxyCommand holds SSH open.
        // This probe never connects to a network host.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        probe.arguments = ["-F", "/dev/null", "-o", "ProxyCommand=/bin/sleep 3", "-o", "BatchMode=yes", "rex-drop-test.invalid"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        defer { if probe.isRunning { probe.terminate() } }
        Thread.sleep(forTimeInterval: 0.1)
        let argv = try DropService.processArgv(probe.processIdentifier)
        guard DropService.parseSSH(Array(argv.dropFirst()))?.last == "rex-drop-test.invalid",
              !(try DropService.processStart(probe.processIdentifier)).isEmpty
        else { throw failure("Native SSH process inspection failed") }
        probe.terminate()
        print("PASS: native SSH argument and process identity inspection (no network).")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rex = home.appendingPathComponent("Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex").path
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rex-drop-smoke-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        let folder = root.appendingPathComponent("sample folder")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sample's file.txt")
        try Data("file payload\n".utf8).write(to: file)
        try Data("folder payload\n".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        let created = try object(command(rex, ["--autostart=false", "new", "rex-drop-smoke-" + UUID().uuidString,
            "--cwd", destination.path, "--shell=none", "--json", "--", "/bin/zsh", "-f"]))
        guard let session = created["session_id"] as? String else { throw failure("Session creation returned no ID") }
        defer { _ = try? command(rex, ["--autostart=false", "kill", session]) }
        var target: [String: Any]?
        for _ in 0..<20 {
            let response = try object(command(app, ["--targets"]))
            target = (response["targets"] as? [[String: Any]])?.first {
                ($0["session_id"] as? String) == session && ($0["selectable"] as? Bool) == true
            }
            if target != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let target, let block = target["block_id"] as? String else { throw failure("Disposable shell was not discovered") }
        let request: [String: Any] = ["target": target, "paths": [file.path, folder.path]]
        let transferred = try object(command(app, ["--transfer"], input: JSONSerialization.data(withJSONObject: request)))
        guard transferred["ok"] as? Bool == true,
              try Data(contentsOf: destination.appendingPathComponent(file.lastPathComponent)) == Data("file payload\n".utf8),
              try Data(contentsOf: destination.appendingPathComponent("sample folder/nested.txt")) == Data("folder payload\n".utf8)
        else { throw failure("File/folder copy failed") }
        let screen = try command(rex, ["--autostart=false", "capture", "-s", session, "-b", block, "--trim", "--unwrap"])
        let text = String(decoding: screen, as: UTF8.self)
        guard text.contains("sample"), text.contains("folder") else { throw failure("Paths were not inserted into the disposable pane") }
        print("PASS: live Rex discovery, local file/folder copy, and path insertion. Disposable session cleaned up.")
    }
    static func main() {
        do { try check() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
