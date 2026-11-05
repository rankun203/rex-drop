import Testing
@testable import RexDrop
import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message) }
}

private func expectThrows(_ message: String? = nil, _ body: () throws -> Void) throws {
    do { try body() }
    catch let failure as TestFailure { throw failure }
    catch {
        if let message {
            try expect(String(describing: error).localizedCaseInsensitiveContains(message),
                       "Expected error containing \(message), received \(error)")
        }
        return
    }
    throw TestFailure("Expected operation to throw")
}

private func temporary(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rex-drop-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func mkdir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

// Every external command is captured here; unit tests never touch SSH or Rex.
private final class FakeRex {
    var calls: [[String]] = []
    var environments: [[String: String]?] = []
    var foregroundName = "zsh"
    var cwd = "/project"
    var blockHost = "local"
    var sshArguments = ["ssh", "-p", "2222", "-o", "IdentityFile=/keys/a b's", "user@example.test"]
    var temporaryOutput = "/tmp/rex-drop.Ab12Cd34\n"
    var enumeration = 0
    var staleAfterCopy = false
    var failRsync = false
    var processCalls = 0
    var sessionsOverride: [[String: Any]]?
    var views: [String: [String: Any]] = [:]
    var processes: [String: [String: Any]] = [:]
    var argvByPID: [Int32: [String]] = [:]
    var sshConfigurations: [String: String] = [:]
    var failWindow = false
    var clients: [[String: Any]] = [["client_id": "client:local", "info": ["kind": "app", "platform": "macos"], "principal": ["transport": "unix", "uid": getuid()], "connection_state": "connected"]]

    func panes(_ definitions: [(String, Int32, String, String)], focused: String? = nil) {
        sessionsOverride = [["session_id": "session:one", "label": "Test session"]]
        let blocks = definitions.map { definition -> [String: Any] in
            processes[definition.0] = ["pid": definition.1, "name": definition.2, "cwd": definition.3]
            return ["block_id": definition.0, "host_id": "local", "label": "shell"]
        }
        var window: [String: Any] = ["window_id": "window:one", "blocks": blocks]
        if let focused { window["focused_block_id"] = focused }
        views["session:one"] = ["active_window_id": "window:one", "windows": [window]]
    }

    func run(_ command: [String], _ timeout: TimeInterval, _ environment: [String: String]?) throws -> Data {
        calls.append(command)
        environments.append(environment)
        if command.first == "/usr/bin/ssh" {
            if command.contains("-G") {
                let host = command.last ?? "example.test"
                return Data((sshConfigurations[host] ?? "hostname example.test\nuser tester\nport 22\n").utf8)
            }
            return Data(temporaryOutput.utf8)
        }
        if command.first == "/usr/bin/rsync" {
            if failRsync { throw TestFailureForCommand() }
            return Data()
        }
        if command.count > 2 && command[2] == "new" {
            return try JSONSerialization.data(withJSONObject: ["session_id": "session:browse"])
        }
        if command.count > 3 && command[2] == "window" && command[3] == "new" {
            return try JSONSerialization.data(withJSONObject: ["window_id": "window:browse"])
        }
        if command.contains("client.window.new") { if failWindow { throw TestFailureForCommand() }; return Data() }
        if command.count > 2 && command[2] == "send" { return Data() }
        if command.count > 3 && command[2] == "client" && command[3] == "ls" {
            return try JSONSerialization.data(withJSONObject: ["clients": clients])
        }
        if command.count > 5 && command[4] == "do" && command[5] == "session.select" { return Data() }
        guard command.count > 4, command[2] == "api", command[3] == "call" else {
            throw TestFailure("Unexpected command: \(command)")
        }
        let result: [String: Any]
        switch command[4] {
        case "server.status":
            enumeration += 1
            result = ["host_id": "local", "instance_id": "test-instance"]
        case "session.list":
            result = ["sessions": sessionsOverride ?? [["session_id": "session:one", "label": "Test session"]]]
        case "session.view":
            let block = ["block_id": "block:one", "host_id": blockHost, "label": "shell"]
            // Rex's view tree can repeat a block in multiple nested locations.
            let arguments = try JSONSerialization.jsonObject(with: Data(command[5].utf8)) as? [String: Any]
            result = views[arguments?["session_id"] as? String ?? ""] ?? ["windows": [["layers": [["blocks": [block, block]]]]]]
        case "com.superlogical.terminal.process":
            processCalls += 1
            let arguments = try JSONSerialization.jsonObject(with: Data(command[5].utf8)) as? [String: Any]
            result = ["foreground": processes[arguments?["block_id"] as? String ?? ""] ?? ["pid": 42, "name": foregroundName, "cwd": cwd]]
        default: throw TestFailure("Unexpected API method: \(command[4])")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    func service(control: DropTaskControl = DropTaskControl(), progress: @escaping (DropProgress) -> Void = { _ in }) -> DropService {
        DropService(runner: { try self.run($0, $1, $2) }, rexPath: "/test/rex",
                    processStart: { _ in self.staleAfterCopy && self.enumeration >= 3 ? "200.2" : "100.1" },
                    processArgv: { self.argvByPID[$0] ?? self.sshArguments }, control: control, progress: progress)
    }

    var sends: [[String]] { calls.filter { $0.count > 2 && $0[2] == "send" } }
    var rsyncs: [[String]] { calls.filter { $0.first == "/usr/bin/rsync" } }
    var sshCalls: [[String]] { calls.filter { $0.first == "/usr/bin/ssh" && !$0.contains("-G") } }
}

private struct TestFailureForCommand: Error, CustomStringConvertible {
    let description = "Command failed"
}

private final class AsyncResult {
    private let lock = NSLock()
    private var storedError: Error?
    private var pidBytes = Data()
    private var storedPID: Int32?
    let finished = DispatchSemaphore(value: 0)
    func finish(_ error: Error?) {
        lock.lock(); storedError = error; lock.unlock()
        finished.signal()
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    var pid: Int32? { lock.lock(); defer { lock.unlock() }; return storedPID }
    func recordPID(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        pidBytes.append(bytes)
        if let line = String(data: pidBytes, encoding: .utf8)?.split(separator: "\n").first {
            storedPID = Int32(line)
        }
    }
}

private final class PauseProgress {
    private let lock = NSLock()
    private var updateCount = 0
    private var didPause = false
    let paused = DispatchSemaphore(value: 0)
    let control: DropTaskControl
    init(_ control: DropTaskControl) { self.control = control }
    var count: Int { lock.lock(); defer { lock.unlock() }; return updateCount }
    func observe(_ update: DropProgress) {
        lock.lock()
        updateCount += 1
        let shouldPause = !didPause && update.currentFile == "item" && update.completedFiles == 0
        if shouldPause { didPause = true }
        lock.unlock()
        if shouldPause { control.pause(); paused.signal() }
    }
}

@Suite(.serialized)
struct BackendTests {
    @Test
    func testSshOptions() throws {
        let parsed = DropService.parseSSH(["-t", "-p2222", "-J", "jump.example.test", "-L", "9000:local:90",
                                           "-o", "IdentityFile=/keys/a b's", "user@example.test", "tmux", "attach"])
        try expect(parsed == ["-p", "2222", "-J", "jump.example.test", "-o", "IdentityFile=/keys/a b's", "user@example.test"], "Connection options changed")
        try expect(DropService.parseSSH(["-o", "ProxyCommand=proxy 'a b'", "example.test", "tmux attach"]) ==
                   ["-o", "ProxyCommand=proxy 'a b'", "example.test"], "Quoted SSH option changed")
    }

    @Test
    func testSshRejections() throws {
        let invalid: [[String]] = [[], ["-N", "example.test"], ["-W", "host:22", "jump.example.test"],
            ["-o", "LocalCommand=bad", "example.test"], ["-p"], ["host;bad"], ["--", "-host"],
            ["example.test", "ssh inner"], ["example.test", "/usr/bin/ssh", "inner"],
            ["example.test", "tmux 'unterminated"]]
        for args in invalid { try expect(DropService.parseSSH(args) == nil, "Accepted unsafe SSH arguments: \(args)") }
    }

    @Test
    func testSourceValidation() throws {
        try temporary { root in
            let file = root.appendingPathComponent("a file's name")
            let folder = root.appendingPathComponent("folder")
            try write("hello", to: file); try mkdir(folder)
            let paths = [file.path, folder.path]
            let validated = try DropService.validateSources(paths)
            try expect(validated == paths, "Valid sources changed")
            for invalid in [[], ["relative"], [file.path, file.path], [root.appendingPathComponent("missing").path],
                            [root.path + "/line\nbreak"], [root.path + "/tab\tname"]] {
                try expectThrows { _ = try DropService.validateSources(invalid) }
            }
            let second = root.appendingPathComponent("second")
            try mkdir(second); try write("same basename", to: second.appendingPathComponent(file.lastPathComponent))
            try expectThrows { _ = try DropService.validateSources([file.path, second.appendingPathComponent(file.lastPathComponent).path]) }
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
            try expectThrows { _ = try DropService.validateSources([link.path]) }
        }
    }

    @Test
    func testLocalCopy() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            let file = source.appendingPathComponent("-a file's name"), folder = source.appendingPathComponent("a folder's name")
            try write("content", to: file); try mkdir(folder)
            try write("nested", to: folder.appendingPathComponent("nested"))
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "nested")
            let copied = try DropService.copyLocal([file.path, folder.path], directory: destination.path)
            try expect(copied == [destination.appendingPathComponent(file.lastPathComponent).path, destination.appendingPathComponent(folder.lastPathComponent).path], "Destination paths changed")
            try expect(try String(contentsOf: URL(fileURLWithPath: copied[0]), encoding: .utf8) == "content", "File content changed")
            let nestedFolder = destination.appendingPathComponent(folder.lastPathComponent)
            try expect(try String(contentsOf: nestedFolder.appendingPathComponent("nested"), encoding: .utf8) == "nested", "Nested content changed")
            let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: nestedFolder.appendingPathComponent("link").path)
            try expect(linkTarget == "nested", "Nested symlink changed")
            let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            try expect(Set(contents) == Set([file.lastPathComponent, folder.lastPathComponent]), "Temporary staging leaked")
        }
    }

    @Test
    func testLocalCollision() throws {
        try temporary { root in
            let file = root.appendingPathComponent("item"), destination = root.appendingPathComponent("target")
            try write("new", to: file); try mkdir(destination)
            let existing = destination.appendingPathComponent("item")
            try write("old", to: existing)
            try expectThrows("already exists") { _ = try DropService.copyLocal([file.path], directory: destination.path) }
            try expect(try String(contentsOf: existing, encoding: .utf8) == "old", "Existing destination overwritten")
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["item"], "Staging leaked on collision")
        }
    }

    @Test
    func testDanglingCollision() throws {
        try temporary { root in
            let file = root.appendingPathComponent("item"), destination = root.appendingPathComponent("target")
            try write("new", to: file); try mkdir(destination)
            let existing = destination.appendingPathComponent("item")
            try FileManager.default.createSymbolicLink(atPath: existing.path, withDestinationPath: "missing")
            try expectThrows { _ = try DropService.copyLocal([file.path], directory: destination.path) }
            try expect(try FileManager.default.destinationOfSymbolicLink(atPath: existing.path) == "missing", "Dangling link overwritten")
        }
    }

    @Test
    func testDescendant() throws {
        try temporary { root in
            let child = root.appendingPathComponent("child"); try mkdir(child)
            try expectThrows("descendant") { _ = try DropService.copyLocal([root.path], directory: child.path) }
            try expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty, "Rejected copy changed destination")
        }
    }

    @Test
    func testEnumeration() throws {
        let fake = FakeRex(); fake.foregroundName = "codex"
        let targets = try fake.service().targets()
        try expect(targets.count == 1, "Repeated block was enumerated twice")
        try expect(targets[0]["selectable"] as? Bool == true, "Coding agent target is unselectable")
        try expect(targets[0]["kind"] as? String == "local", "Coding agent kind differs")
        try expect((targets[0]["detail"] as? String)?.contains("codex") == true, "Coding agent absent from detail")
        for env in fake.environments {
            try expect(env != nil && env!.keys.allSatisfy { !$0.hasPrefix("REX") }, "Rex environment overrides leaked")
        }
    }

    @Test
    func testStagingFailure() throws {
        try temporary { root in
            let file = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try write("data", to: file); try mkdir(destination)
            // A source can disappear between validation and the staged read.
            try expectThrows {
                _ = try DropService.copyLocal([file.path, root.appendingPathComponent("vanished").path], directory: destination.path)
            }
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                       "Staging failure published a partial batch")
        }
    }

    @Test
    func testEnvironment() throws {
        let actual = DropService.localEnvironment(["REX_SERVER": "remote:1234", "REX_SESSION": "other", "REX_BIN_DIR": "/remote", "KEEP": "yes"])
        try expect(actual == ["KEEP": "yes"], "Local Rex endpoint overrides survived")
    }

    @Test
    func testInvalidAPI() throws {
        let service = DropService(runner: { _, _, _ in Data("bad json".utf8) }, rexPath: "/test/rex")
        try expectThrows("invalid API response") { _ = try service.targets() }
    }

    @Test
    func testRemoteBlock() throws {
        let fake = FakeRex(); fake.blockHost = "remote"
        let targets = try fake.service().targets()
        try expect(targets.isEmpty, "Remote Rex pane appeared as drop destination")
        try expect(fake.processCalls == 0, "Inspected local PID for remote Rex pane")
    }

    @Test
    func testUnsupportedEditor() throws {
        let fake = FakeRex(); fake.foregroundName = "nvim"
        let targets = try fake.service().targets()
        try expect(targets.isEmpty, "Editor appeared as drop destination")
    }

    @Test
    func testFingerprint() throws {
        let fake = FakeRex(); fake.foregroundName = "ssh"
        let service = fake.service(), first = try service.targets()[0]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self)
        try expect(!json.contains("/keys/"), "Private connection arguments exposed in target")
        fake.sshArguments = ["ssh", "-i", "/different/key", "user@example.test"]
        let second = try service.targets()[0]
        try expect(first["fingerprint"] as? String != second["fingerprint"] as? String, "Connection change retained fingerprint")
    }

    @Test
    func testLocalTransfer() throws {
        try temporary { root in
            let source = root.appendingPathComponent("a file's name"), destination = root.appendingPathComponent("destination")
            try write("data", to: source); try mkdir(destination)
            let fake = FakeRex(); fake.cwd = destination.path
            let service = fake.service(), target = try service.targets()[0]
            let result = try service.transfer(["target": target, "paths": [source.path]])
            try expect(result["ok"] as? Bool == true, "Transfer missing success")
            try expect(fake.sends.count == 1, "Transfer must insert once")
            let command = fake.sends[0]
            try expect(Array(command.prefix(8)) == ["/test/rex", "--autostart=false", "send", "-s", "session:one", "-b", "block:one", "--"], "Insertion changed pinned pane")
            try expect(command.count == 9, "Unexpected send options")
            let expected = DropService.shellQuote(destination.appendingPathComponent(source.lastPathComponent).path) + " "
            try expect(command.last == expected, "Inserted path quoting changed")
            try expect(!command.last!.contains("\n") && !command.last!.contains("\r"), "Insertion pressed Enter")
            try expect(fake.enumeration == 3, "Transfer omitted one target revalidation")
        }
    }

    @Test
    func testStaleTransfer() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try write("data", to: source); try mkdir(destination)
            let fake = FakeRex(); fake.cwd = destination.path; fake.staleAfterCopy = true
            let service = fake.service(), target = try service.targets()[0]
            try expectThrows("Files copied") { _ = try service.transfer(["target": target, "paths": [source.path]]) }
            try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("item").path), "Copy should finish before stale selection detected")
            try expect(fake.sends.isEmpty, "Stale selection received pane input")
        }
    }

    @Test
    func testRemoteTransfer() throws {
        try temporary { root in
            let source = root.appendingPathComponent("-a file's name"); try write("data", to: source)
            let fake = FakeRex(); fake.foregroundName = "ssh"
            let service = fake.service(), target = try service.targets()[0]
            let result = try service.transfer(["target": target, "paths": [source.path]])
            try expect(result["paths"] as? [String] == ["/tmp/rex-drop.Ab12Cd34/-a file's name"], "Remote destination changed")
            try expect(fake.sshCalls.count == 1 && fake.rsyncs.count == 1, "Unexpected remote command count")
            let setup = fake.sshCalls[0], copy = fake.rsyncs[0]
            try expect(setup.contains("BatchMode=yes"), "SSH may prompt interactively")
            try expect(setup.last?.contains("command -v rsync") == true, "Missing remote rsync availability check")
            try expect(Array(copy.prefix(3)) == ["/usr/bin/rsync", "-rlt", "-e"], "Unexpected rsync options")
            try expect(!copy.contains("--delete"), "Destructive rsync mode selected")
            try expect(copy[3].contains("IdentityFile=/keys/a b"), "SSH transport lost connection identity")
            try expect(copy[3].contains("2222"), "SSH transport lost port")
            try expect(DropService.shellWords(copy[3]) == Array(setup.dropLast(2)), "SSH transport quoting changed connection arguments")
            try expect(Array(copy.suffix(3)) == ["--", source.path, "user@example.test:/tmp/rex-drop.Ab12Cd34/"], "Source or remote destination split")
            try expect(fake.sends.count == 1, "Successful remote copy missing insertion")
        }
    }

    @Test
    func testUnexpectedRemotePath() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"); try write("data", to: source)
            for output in ["/tmp/rex-drop.ABCDEFGH; bad", "/tmp/rex-drop.ABCDEFGH\nnoise", "/tmp/other.ABCDEFGH", "/tmp/rex-drop.short"] {
                let fake = FakeRex(); fake.foregroundName = "ssh"; fake.temporaryOutput = output
                let service = fake.service(), target = try service.targets()[0]
                try expectThrows("unexpected") { _ = try service.transfer(["target": target, "paths": [source.path]]) }
                try expect(fake.rsyncs.isEmpty && fake.sends.isEmpty, "Untrusted temporary path reached copy or insertion")
            }
        }
    }

    @Test
    func testFailedRemoteTransfer() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"); try write("data", to: source)
            let fake = FakeRex(); fake.foregroundName = "ssh"; fake.failRsync = true
            let service = fake.service(), target = try service.targets()[0]
            try expectThrows("Partial files may remain in /tmp/rex-drop.Ab12Cd34") { _ = try service.transfer(["target": target, "paths": [source.path]]) }
            try expect(fake.sends.isEmpty, "Failed transfer inserted paths")
        }
    }

    @Test
    func testChangedSelection() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try write("data", to: source); try mkdir(destination)
            let fake = FakeRex(); fake.cwd = destination.path
            let service = fake.service(); var target = try service.targets()[0]
            target["fingerprint"] = "stale"
            try expectThrows("changed") { _ = try service.transfer(["target": target, "paths": [source.path]]) }
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Changed selection copied files")
            try expect(fake.sends.isEmpty, "Changed selection inserted paths")
        }
    }

    @Test
    func testQuoting() throws {
        try expect(DropService.shellQuote("/tmp/a file's name") == "'/tmp/a file'\"'\"'s name'", "Apostrophe shell quoting changed")
    }

    @Test
    func testCommandError() throws {
        do {
            _ = try DropService.run(["/bin/sh", "-c", "printf 'private key /secret/key' >&2; exit 1"], 2, nil)
            throw TestFailure("Failed process was accepted")
        } catch let failure as TestFailure { throw failure }
        catch {
            try expect(!error.localizedDescription.contains("/secret/key"), "Command stderr leaked into error")
            try expect(error.localizedDescription.contains("Command failed"), "Command error lost useful context")
        }
    }

    @Test
    func testCommandTimeout() throws {
        let start = Date()
        try expectThrows("timed out") { _ = try DropService.run(["/bin/sleep", "10"], 0.05, nil) }
        try expect(Date().timeIntervalSince(start) < 4, "Timed out process remained blocking")
    }

    @Test
    func testLocalDestinationDeduplication() throws {
        try temporary { root in
            let folder = root.appendingPathComponent("Shared"), alias = root.appendingPathComponent("alias")
            try mkdir(folder)
            try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: folder.path)
            let fake = FakeRex()
            fake.panes([("block:a", 41, "zsh", folder.path), ("block:b", 42, "codex", alias.path + "/../alias")])
            let targets = try fake.service().targets()
            try expect(targets.count == 1, "Equivalent canonical folders produced duplicate destinations")
            try expect(targets[0]["display_name"] as? String == "Shared", "Local display name is not folder basename")
            let detail = targets[0]["detail"] as? String ?? ""
            try expect(detail.contains(folder.resolvingSymlinksInPath().path), "Local detail omitted canonical path")
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: targets[0]), as: UTF8.self)
            try expect(!serialized.contains("_preferred"), "Private representative metadata escaped public target list")
        }
    }

    @Test
    func testSshDestinationDeduplication() throws {
        let fake = FakeRex()
        fake.panes([("block:b", 42, "ssh", "/"), ("block:a", 41, "ssh", "/")])
        fake.argvByPID = [41: ["ssh", "-i", "/keys/one", "alias-one"], 42: ["ssh", "-i", "/keys/two", "alias-two"]]
        fake.sshConfigurations = ["alias-one": "hostname shared.example.test\nuser alice\nport 22\nproxyjump none\nproxycommand none\n",
                                  "alias-two": "hostname shared.example.test\nuser alice\nport 22\nproxyjump none\nproxycommand none\n"]
        let targets = try fake.service().targets()
        try expect(targets.count == 1, "SSH aliases to same effective endpoint produced duplicates")
        try expect(targets[0]["display_name"] as? String == "alice@shared.example.test", "Effective SSH endpoint is absent from display name")
        try expect(targets[0]["block_id"] as? String == "block:a", "Stable representative should prefer lexicographically first pane")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: targets), as: UTF8.self)
        try expect(!serialized.contains("/keys/"), "Connection identity leaked into destination metadata")
    }

    @Test
    func testDistinctSSHDestinations() throws {
        let fake = FakeRex()
        fake.panes([("block:a", 41, "ssh", "/"), ("block:b", 42, "ssh", "/"), ("block:c", 43, "ssh", "/")])
        fake.argvByPID = [41: ["ssh", "default"], 42: ["ssh", "other-user"], 43: ["ssh", "other-port"]]
        fake.sshConfigurations = ["default": "hostname shared.example.test\nuser alice\nport 22\n",
                                  "other-user": "hostname shared.example.test\nuser bob\nport 22\n",
                                  "other-port": "hostname shared.example.test\nuser alice\nport 2222\n"]
        let targets = try fake.service().targets()
        try expect(targets.count == 3, "Distinct user or SSH port was collapsed")
        let names = targets.compactMap { $0["display_name"] as? String }
        try expect(Set(names) == Set(["alice@shared.example.test", "bob@shared.example.test", "alice@shared.example.test:2222"]), "SSH identity display changed")
    }

    @Test
    func testDestinationSorting() throws {
        let fake = FakeRex()
        fake.panes([("block:z", 41, "zsh", "/project/Zebra"), ("block:y", 42, "ssh", "/"),
                    ("block:a", 43, "zsh", "/project/alpha"), ("block:b", 44, "ssh", "/")])
        fake.argvByPID = [42: ["ssh", "z-host"], 44: ["ssh", "a-host"]]
        fake.sshConfigurations = ["z-host": "hostname zulu.example.test\nuser Bob\nport 22\n",
                                  "a-host": "hostname alpha.example.test\nuser alice\nport 22\n"]
        let targets = try fake.service().targets()
        try expect(targets.compactMap { $0["kind"] as? String } == ["ssh", "ssh", "local", "local"], "SSH destinations did not sort first")
        try expect(targets.compactMap { $0["display_name"] as? String } == ["alice@alpha.example.test", "Bob@zulu.example.test", "alpha", "Zebra"], "Destination alphabetization changed")
    }

    @Test
    func testRepresentativeSelection() throws {
        let fake = FakeRex()
        fake.panes([("block:a", 41, "zsh", "/project"), ("block:z", 42, "zsh", "/project")], focused: "block:z")
        let service = fake.service()
        let allPanes = try service.enumerate().0
        guard let hidden = allPanes.first(where: { $0["block_id"] as? String == "block:a" }) else { throw TestFailure("Missing hidden duplicate pane") }
        let targets = try service.targets()
        try expect(targets.count == 1 && targets[0]["block_id"] as? String == "block:z", "Active window's focused pane did not represent duplicate destination")
        _ = try service.revalidate(hidden)
        fake.panes([("block:z", 42, "zsh", "/project"), ("block:a", 41, "zsh", "/project")], focused: "block:z")
        let reordered = try service.targets()
        try expect(reordered[0]["block_id"] as? String == "block:z", "Representative depended on enumeration order")
        fake.panes([("block:z", 42, "zsh", "/project"), ("block:a", 41, "zsh", "/project")])
        let unfocused = try service.targets()
        try expect(unfocused[0]["block_id"] as? String == "block:a", "Unfocused representative was nondeterministic")
    }

    @Test
    func testPauseResume() throws {
        let control = DropTaskControl(), result = AsyncResult(), entered = DispatchSemaphore(value: 0)
        control.pause()
        defer { control.cancel() }
        DispatchQueue.global().async {
            entered.signal()
            do { try control.checkpoint(); result.finish(nil) }
            catch { result.finish(error) }
        }
        try expect(entered.wait(timeout: .now() + 1) == .success, "Checkpoint worker did not start")
        try expect(result.finished.wait(timeout: .now() + 0.1) == .timedOut, "Paused checkpoint advanced work")
        control.resume()
        try expect(result.finished.wait(timeout: .now() + 1) == .success, "Resume failed to unblock checkpoint")
        try expect(result.error == nil && !control.isPaused, "Resume left checkpoint in error")
    }

    @Test
    func testCancelPaused() throws {
        let control = DropTaskControl(), result = AsyncResult(), entered = DispatchSemaphore(value: 0)
        control.pause()
        defer { control.cancel() }
        DispatchQueue.global().async {
            entered.signal()
            do { try control.checkpoint(); result.finish(nil) }
            catch { result.finish(error) }
        }
        try expect(entered.wait(timeout: .now() + 1) == .success, "Paused worker did not start")
        try expect(result.finished.wait(timeout: .now() + 0.1) == .timedOut, "Paused task completed early")
        control.cancel()
        try expect(result.finished.wait(timeout: .now() + 1) == .success, "Cancel failed to wake paused checkpoint")
        try expect(result.error?.localizedDescription.localizedCaseInsensitiveContains("cancel") == true, "Cancelled checkpoint omitted cancellation error")
        try expect(control.isCancelled && !control.isPaused, "Cancelled task retained paused state")
    }

    @Test
    func testPauseLocalCopy() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try Data(repeating: 65, count: 2 * 1024 * 1024).write(to: source); try mkdir(destination)
            let control = DropTaskControl(), result = AsyncResult(), probe = PauseProgress(control)
            defer { control.cancel() }
            DispatchQueue.global().async {
                do {
                    _ = try DropService.copyLocal([source.path], directory: destination.path, control: control, progress: probe.observe)
                    result.finish(nil)
                } catch { result.finish(error) }
            }
            try expect(probe.paused.wait(timeout: .now() + 1) == .success, "Copy never reached cancellable progress")
            let count = probe.count
            try expect(result.finished.wait(timeout: .now() + 0.1) == .timedOut, "Paused local copy completed")
            try expect(probe.count == count, "Paused local copy kept advancing progress")
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("item").path), "Paused local copy published destination")
            control.resume()
            try expect(result.finished.wait(timeout: .now() + 1) == .success, "Resumed local copy remained blocked")
            try expect(result.error == nil, "Resumed local copy failed: \(String(describing: result.error))")
        }
    }

    @Test
    func testCancelSubprocess() throws {
        let control = DropTaskControl(), result = AsyncResult(), running = DispatchSemaphore(value: 0)
        defer { control.cancel() }
        DispatchQueue.global().async {
            do {
                _ = try DropService.runControlled(["/bin/sh", "-c", "printf '%s\\n' \"$$\"; exec /bin/sleep 10"], 2, nil,
                                                  control: control, output: { bytes in
                    result.recordPID(bytes)
                    if result.pid != nil { running.signal() }
                })
                result.finish(nil)
            } catch { result.finish(error) }
        }
        try expect(running.wait(timeout: .now() + 1) == .success, "Controlled subprocess failed to start")
        let start = Date()
        control.cancel()
        try expect(result.finished.wait(timeout: .now() + 2) == .success, "Cancelled subprocess continued blocking")
        try expect(Date().timeIntervalSince(start) < 3, "Subprocess cancellation exceeded bound")
        try expect(result.error?.localizedDescription.localizedCaseInsensitiveContains("cancel") == true, "Subprocess returned a different result after cancellation")
        guard let pid = result.pid else { throw TestFailure("Controlled subprocess omitted its process identity") }
        try expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "Cancelled subprocess remained alive")
    }

    @Test
    func testCancelLocalTransfer() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try Data(repeating: 65, count: 2 * 1024 * 1024).write(to: source); try mkdir(destination)
            let fake = FakeRex(); fake.cwd = destination.path
            let control = DropTaskControl()
            var sawFileProgress = false
            let service = fake.service(control: control) { update in
                if update.currentFile == "item" && update.completedFiles == 0 {
                    sawFileProgress = true
                    control.cancel()
                }
            }
            let target = try service.targets()[0]
            try expectThrows("cancel") { _ = try service.transfer(["target": target, "paths": [source.path]]) }
            try expect(sawFileProgress, "No cancellable file progress arrived")
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Cancelled local copy published or leaked staging")
            try expect(fake.sends.isEmpty, "Cancelled local copy inserted paths")
        }
    }

    @Test
    func testLocalProgress() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            let folder = source.appendingPathComponent("folder"), file = source.appendingPathComponent("item")
            try mkdir(folder); try write("nested", to: folder.appendingPathComponent("nested"))
            try Data(repeating: 65, count: 2 * 1024 * 1024).write(to: file)
            let fake = FakeRex(); fake.cwd = destination.path
            var updates: [DropProgress] = []
            let service = fake.service { updates.append($0) }
            let target = try service.targets()[0]
            _ = try service.transfer(["target": target, "paths": [file.path, folder.path]])
            try expect(!updates.isEmpty, "Transfer emitted no progress")
            var previousFraction = 0.0, previousCompleted = 0
            for update in updates {
                try expect(update.completedFiles >= previousCompleted && update.completedFiles <= update.totalFiles, "Completed file count went backwards or exceeded total")
                previousCompleted = update.completedFiles
                if let fraction = update.fraction {
                    try expect(fraction >= previousFraction && fraction <= 1 && fraction >= 0, "Progress fraction went backwards or exceeded bounds")
                    previousFraction = fraction
                }
            }
            try expect(updates.last?.fraction == 1, "Successful transfer omitted final completion")
            try expect((updates.last?.completedFiles ?? 0) > 0, "Successful transfer reported no completed files")
            try expect(updates.contains { $0.currentFile == "item" || $0.currentFile == "nested" }, "Progress omitted current file")
        }
    }

    @Test
    func testCancelBeforePublication() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try write("staged data", to: source); try mkdir(destination)
            let fake = FakeRex(); fake.cwd = destination.path
            let control = DropTaskControl()
            var staged = false
            let service = fake.service(control: control) { update in
                if update.phase == "Copying" && update.totalFiles > 0 && update.completedFiles == update.totalFiles {
                    staged = true
                    control.cancel()
                }
            }
            let target = try service.targets()[0]
            try expectThrows("cancel") { _ = try service.transfer(["target": target, "paths": [source.path]]) }
            try expect(staged, "Cancellation failed to reach fully staged batch")
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                       "Cancelled staged batch published destination or retained staging")
            try expect(fake.sends.isEmpty, "Cancelled staged batch inserted pane input")
        }
    }

    @Test
    func testRsyncProgress() throws {
        try temporary { root in
            let file = root.appendingPathComponent("item"); try write("data", to: file)
            let fake = FakeRex(); fake.foregroundName = "ssh"
            var updates: [DropProgress] = []
            let service = fake.service { updates.append($0) }, target = try service.targets()[0]
            _ = try service.transfer(["target": target, "paths": [file.path]])
            try expect(fake.rsyncs[0].contains("--progress"), "Remote transfer omitted supported rsync progress")
            try expect(!fake.rsyncs[0].contains(where: { $0.hasPrefix("--info=") || $0 == "--outbuf=L" }), "Remote progress requires newer rsync than macOS ships")
            try expect(updates.contains { $0.fraction == nil }, "Remote setup should report indeterminate work")
            try expect(updates.last?.fraction == 1, "Remote success omitted final progress")
        }
    }

    @Test
    func testCompletedDestinations() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try write("data", to: source); try mkdir(destination)
            let fake = FakeRex(); fake.cwd = destination.path
            let localService = fake.service(), localTarget = try localService.targets()[0]
            let local = try localService.transfer(["target": localTarget, "paths": [source.path]])
            let localOpen = local["open_destination"] as? [String: Any] ?? [:]
            try expect(localOpen["kind"] as? String == "local" && localOpen["directory"] as? String == destination.path,
                       "Local reveal omitted actual destination directory")
            try expect(localOpen["paths"] as? [String] == [destination.appendingPathComponent("source").path], "Local reveal omitted copied paths")
            fake.foregroundName = "ssh"
            let remoteService = fake.service(), remoteTarget = try remoteService.targets()[0]
            let remote = try remoteService.transfer(["target": remoteTarget, "paths": [source.path]])
            let remoteOpen = remote["open_destination"] as? [String: Any] ?? [:]
            try expect(remoteOpen["directory"] as? String == "/tmp/rex-drop.Ab12Cd34", "Remote reveal used /tmp instead of actual private directory")
            try expect(remoteOpen["ssh_args"] as? [String] == Array(fake.sshArguments.dropFirst()), "Remote reveal lost original SSH identity")
            try expect(remoteOpen["session_id"] as? String == "session:one", "Remote reveal lost original session")
            try expect(remoteTarget["ssh_args"] == nil && remoteTarget["open_destination"] == nil, "Private connection options leaked into target metadata")
        }
    }

    private func remoteMetadata() -> [String: Any] {
        ["kind": "ssh", "session_id": "session:original", "directory": "/tmp/rex-drop.Ab12Cd34",
         "ssh_args": ["-p", "2222", "-o", "IdentityFile=/keys/a b's", "user@example.test"]]
    }

    @Test
    func testOpenRemoteDestination() throws {
        let fake = FakeRex()
        try fake.service().openRemoteDestination(remoteMetadata())
        let command = fake.calls.first { $0.count > 2 && $0[2] == "new" }!
        try expect(Array(command.prefix(4)) == ["/test/rex", "--autostart=false", "new", "Rex Drop"], "Remote folder should use a dedicated session")
        try expect(command.contains("--shell=none") && command.contains("--keep-open") && command.contains("--json"), "Remote tab should execute exact argv and retain connection errors")
        guard let separator = command.firstIndex(of: "--") else { throw TestFailure("Command boundary missing") }
        let ssh = Array(command.dropFirst(separator + 1))
        try expect(Array(ssh.prefix(2)) == ["/usr/bin/ssh", "-t"], "Remote tab did not request an interactive SSH terminal")
        let args = remoteMetadata()["ssh_args"] as! [String]
        try expect(Array(ssh.suffix(args.count + 1).dropLast()) == args, "SSH identity or quote-containing option changed")
        let words = DropService.shellWords(ssh.last ?? "") ?? []
        try expect(Array(words.prefix(3)) == ["exec", "/bin/sh", "-c"], "Remote command lacks explicit POSIX shell")
        try expect(words.count == 4 && words[3].contains("cd '/tmp/rex-drop.Ab12Cd34' && ls -ltr"), "Remote listing targets the wrong directory")
        try expect(words[3].hasSuffix("exec \"${SHELL:-/bin/sh}\" -i"), "Interactive shell could reset upload directory")
        try expect(!ssh.contains("RequestTTY=no") && !ssh.contains("StdinNull=yes"), "Reopen reused noninteractive upload settings")
    }

    @Test
    func testSelectOpenedRemoteWindow() throws {
        let app: [String: Any] = ["client_id": "client:local", "info": ["kind": "app", "platform": "macos"],
                                 "principal": ["transport": "unix", "uid": getuid()], "connection_state": "connected"]
        let fake = FakeRex(); fake.clients = [app]
        try fake.service().openRemoteDestination(remoteMetadata())
        try expect(fake.calls.last == ["/test/rex", "--autostart=false", "-C", "client:local", "do", "session.select",
                                      "session_id=session:browse"], "Created tab was not selected on the identified Mac app")
        let ambiguous = FakeRex(); ambiguous.clients = [app, app]
        try expectThrows("Open one local Rex") { try ambiguous.service().openRemoteDestination(remoteMetadata()) }
        try expect(!ambiguous.calls.contains { $0.contains("session.select") }, "Ambiguous local clients should retain their selected session")
    }

    @Test
    func testDisabledRemoteControlOpensFolderInTab() throws {
        let fake = FakeRex(); fake.failWindow = true
        try fake.service().openRemoteDestination(remoteMetadata())
        guard let command = fake.calls.last else { throw TestFailure("Missing fallback tab") }
        try expect(Array(command.prefix(6)) == ["/test/rex", "--autostart=false", "window", "new", "-s", "session:original"],
                   "Disabled Remote Control should open a tab in the captured session")
        try expect(command.contains("--shell=none") && command.contains("--keep-open"), "Fallback lost interactive SSH configuration")
        let script = DropService.shellWords(command.last ?? "") ?? []
        try expect(script.last?.contains("cd '/tmp/rex-drop.Ab12Cd34' && ls -ltr") == true, "Fallback opened the wrong folder")
        try expect(!fake.calls.contains { $0.contains("session.select") }, "Fallback retried disabled client control")
    }

    @Test
    func testRejectRemoteDestination() throws {
        for key in ["directory", "ssh_args", "session_id"] {
            var metadata = remoteMetadata()
            if key == "directory" { metadata[key] = "/tmp/rex-drop.Ab12Cd34; echo bad" }
            if key == "ssh_args" { metadata[key] = ["host", "echo bad"] }
            if key == "session_id" { metadata[key] = "session:one\nother" }
            let fake = FakeRex()
            try expectThrows("unavailable") { try fake.service().openRemoteDestination(metadata) }
            try expect(fake.calls.isEmpty, "Malformed reopen metadata executed an external command")
        }
    }

    @Test
    func testConflictChoices() throws {
        try temporary { root in
            let source = root.appendingPathComponent("item"), destination = root.appendingPathComponent("destination")
            try write("new", to: source); try mkdir(destination); try write("old", to: destination.appendingPathComponent("item"))
            let fake = FakeRex(); fake.cwd = destination.path
            let service = fake.service(), target = try service.targets()[0]
            do {
                _ = try service.transfer(["target": target, "paths": [source.path], "collision_policy": "unknown"])
                throw TestFailure("Expected typed collision")
            } catch let conflict as LocalConflict {
                try expect(conflict.paths == [destination.appendingPathComponent("item").path], "Conflict omitted actual destination")
            }
            try expect(try String(contentsOf: destination.appendingPathComponent("item"), encoding: .utf8) == "old", "Ask modified original")
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["item"] && fake.sends.isEmpty, "Ask staged or inserted input")
        }
    }

    @Test
    func testKeepBoth() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            let first = source.appendingPathComponent("report.txt"), second = source.appendingPathComponent("report 2.txt")
            try write("first", to: first); try write("second", to: second)
            try write("old", to: destination.appendingPathComponent("report.txt"))
            let folder = source.appendingPathComponent("folder.v1"); try mkdir(folder); try mkdir(destination.appendingPathComponent("folder.v1"))
            let fake = FakeRex(); fake.cwd = destination.path
            let service = fake.service(), target = try service.targets()[0]
            let response = try service.transfer(["target": target, "paths": [first.path, second.path, folder.path], "collision_policy": "keepBoth"])
            let names = (response["paths"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
            try expect(names == ["report 3.txt", "report 2.txt", "folder.v1 2"], "Keep Both consumed another incoming name or changed directory extension")
            try expect(try String(contentsOf: destination.appendingPathComponent("report.txt"), encoding: .utf8) == "old", "Keep Both changed original")
            let other = root.appendingPathComponent("other"); try mkdir(other); try write("duplicate", to: other.appendingPathComponent("report.txt"))
            let duplicateNames = try DropService.copyLocal([first.path, other.appendingPathComponent("report.txt").path], directory: destination.path, collisionPolicy: .keepBoth).map { ($0 as NSString).lastPathComponent }
            try expect(duplicateNames == ["report 4.txt", "report 5.txt"], "Keep Both failed duplicate source basenames")
        }
    }

    @Test
    func testReplaceEntries() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            let file = source.appendingPathComponent("item"), folder = source.appendingPathComponent("folder"), linkFile = source.appendingPathComponent("link")
            try write("new", to: file); try mkdir(folder); try write("nested", to: folder.appendingPathComponent("new")); try write("replacement", to: linkFile)
            try write("old", to: destination.appendingPathComponent("item")); try mkdir(destination.appendingPathComponent("folder"))
            try write("old child", to: destination.appendingPathComponent("folder/old"))
            let outside = root.appendingPathComponent("outside"); try write("untouched", to: outside)
            try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent("link").path, withDestinationPath: outside.path)
            _ = try DropService.copyLocal([file.path, folder.path, linkFile.path], directory: destination.path, collisionPolicy: .replace)
            try expect(try String(contentsOf: destination.appendingPathComponent("item"), encoding: .utf8) == "new", "Replace omitted file")
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("folder").path) == ["new"], "Replace merged nonempty folders")
            try expect(try String(contentsOf: outside, encoding: .utf8) == "untouched", "Replace followed destination symlink")
            try expectThrows("itself") { _ = try DropService.copyLocal([destination.appendingPathComponent("item").path], directory: destination.path, collisionPolicy: .replace) }
            try FileManager.default.removeItem(at: destination.appendingPathComponent("item"))
            try FileManager.default.linkItem(at: file, to: destination.appendingPathComponent("item"))
            try expectThrows("itself") { _ = try DropService.copyLocal([file.path], directory: destination.path, collisionPolicy: .replace) }
            try FileManager.default.removeItem(at: destination.appendingPathComponent("item"))
            try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent("item").path, withDestinationPath: file.path)
            try expectThrows("itself") { _ = try DropService.copyLocal([file.path], directory: destination.path, collisionPolicy: .replace) }
            try expectThrows("containing") { _ = try DropService.copyLocal([folder.path, destination.appendingPathComponent("folder/new").path], directory: destination.path, collisionPolicy: .replace) }
        }
    }

    @Test
    func testCancelReplacement() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            for name in ["a", "b"] { try write("new " + name, to: source.appendingPathComponent(name)); try write("old " + name, to: destination.appendingPathComponent(name)) }
            let control = DropTaskControl()
            try expectThrows("cancel") {
                _ = try DropService.copyLocal([source.appendingPathComponent("a").path, source.appendingPathComponent("b").path], directory: destination.path, control: control, progress: { event in
                    if event.phase == "Replacing" && event.currentFile == "b" { control.cancel() }
                }, collisionPolicy: .replace)
            }
            for name in ["a", "b"] { try expect(try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8) == "old " + name, "Cancellation lost an original") }
        }
    }

    @Test
    func testPublicationRace() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            for name in ["a", "b"] { try write("new", to: source.appendingPathComponent(name)) }
            do {
                _ = try DropService.copyLocal([source.appendingPathComponent("a").path, source.appendingPathComponent("b").path], directory: destination.path, progress: { event in
                    if event.phase == "Publishing" && event.currentFile == "b" { try! write("other writer", to: destination.appendingPathComponent("b")) }
                })
                throw TestFailure("Expected publication conflict")
            } catch let conflict as LocalConflict { try expect(conflict.recoveryDirectory != nil, "Rollback copies omitted recovery path") }
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("a").path), "Race left sibling published before choice")
            try expect(try String(contentsOf: destination.appendingPathComponent("b"), encoding: .utf8) == "other writer", "Race overwrote concurrent writer")
        }
    }

    @Test
    func testRollbackFolderEdits() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            let folder = source.appendingPathComponent("folder"), oldFolder = destination.appendingPathComponent("folder")
            try mkdir(folder); try write("new", to: folder.appendingPathComponent("copied")); try mkdir(oldFolder); try write("original", to: oldFolder.appendingPathComponent("old"))
            let second = source.appendingPathComponent("second"); try write("second", to: second)
            let control = DropTaskControl()
            try expectThrows("recovery") {
                _ = try DropService.copyLocal([folder.path, second.path], directory: destination.path, control: control, progress: { event in
                    if event.phase == "Publishing" && event.currentFile == "second" {
                        try! write("user work", to: oldFolder.appendingPathComponent("user-work")); control.cancel()
                    }
                }, collisionPolicy: .replace)
            }
            try expect(try String(contentsOf: oldFolder.appendingPathComponent("old"), encoding: .utf8) == "original", "Rollback lost original folder")
            let recovery = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".rex-drop-") }
            guard let recovery else { throw TestFailure("Concurrent directory edits lost without recovery folder") }
            try expect(try String(contentsOf: recovery.appendingPathComponent("item-0/user-work"), encoding: .utf8) == "user work", "Rollback deleted edits inside published folder")
        }
    }

    @Test
    func testDestinationOpeningUsesActualLocalDirectory() throws {
        let fake = FakeRex(); fake.cwd = "/actual/project"
        let service = fake.service()
        var target = try service.targets()[0]
        target["destination_path"] = "/untrusted/row/path"
        let metadata = try service.destinationToOpen(target)
        try expect(metadata["kind"] as? String == "local" && metadata["directory"] as? String == "/actual/project",
                   "Folder opening trusted displayed metadata instead of the validated shell cwd")
        try expect(metadata["ssh_args"] == nil && fake.sends.isEmpty && fake.sshCalls.isEmpty,
                   "Local folder lookup started a transfer or exposed SSH options")
        fake.cwd = "/different/project"
        try expectThrows("changed") { _ = try service.destinationToOpen(target) }
        try expect(!fake.calls.contains { $0.count > 2 && $0[2] == "new" },
                   "Stale destination opened a new terminal")
    }

    @Test
    func testDestinationOpeningUsesCapturedSSHConnectionAtTmp() throws {
        let fake = FakeRex(); fake.foregroundName = "ssh"
        let service = fake.service(), target = try service.targets()[0]
        let metadata = try service.destinationToOpen(target)
        try expect(metadata["kind"] as? String == "ssh" && metadata["directory"] as? String == "/tmp",
                   "SSH destination lookup omitted the advertised temporary folder")
        try expect(metadata["session_id"] as? String == "session:one" &&
                   metadata["ssh_args"] as? [String] == Array(fake.sshArguments.dropFirst()),
                   "SSH destination lookup lost the validated session or connection options")
        try expect(target["ssh_args"] == nil, "Private SSH options leaked into destination discovery")
        try service.openRemoteDestination(metadata)
        guard let command = fake.calls.first(where: { $0.count > 2 && $0[2] == "new" }) else {
            throw TestFailure("SSH browsing did not open a Rex tab")
        }
        let shell = DropService.shellWords(command.last ?? "") ?? []
        try expect(shell.count == 4 && shell[3].contains("cd '/tmp' && ls -ltr") && shell[3].hasSuffix(" -i"),
                   "SSH browsing listed the wrong folder or omitted its interactive shell")
        let args = Array(fake.sshArguments.dropFirst())
        try expect(Array(command.suffix(args.count + 1).dropLast()) == args,
                   "SSH browsing changed quote-containing identity options")
        try expect(fake.sends.isEmpty && fake.rsyncs.isEmpty, "Opening a destination started a transfer")
    }

    @Test
    func testDestinationOpeningRejectsArbitraryRemoteDirectories() throws {
        for directory in ["/", "/tmp/", "/tmp/other", "/tmp/rex-drop.Ab12Cd34/child", "/tmp; echo bad"] {
            let fake = FakeRex()
            var metadata = remoteMetadata(); metadata["directory"] = directory
            try expectThrows("unavailable") { try fake.service().openRemoteDestination(metadata) }
            try expect(fake.calls.isEmpty, "Arbitrary browsing path reached an external command")
        }
    }

    @Test
    func testRemoteProgressAggregatesActualRsyncFileCounters() throws {
        var tracker = RemoteProgressTracker(totalBytes: 327_683, totalFiles: 2)
        let output = """
        REX-DROP:first.bin
                 163840  83%  159.51KB/s   00:00:00\r         196608 100%  191.31KB/s   00:00:01 (xfer#1, to-check=0/5)
                 196608 100%  191.31KB/s   00:00:01 (xfer#1, to-check=0/5)
        REX-DROP:folder/
        REX-DROP:folder/a file.bin
                  98,304  75%   95.96KB/s   00:00:00\r         131,072 100%  127.90KB/s   00:00:01 (xfer#2, to-check=2/5)
        REX-DROP:folder/last.txt
                       3 100%   26.83KB/s   00:00:00 (xfer#3, to-check=3/5)
        REX-DROP:folder/link
        """
        let bytes = Array(output.utf8)
        var updates: [DropProgress] = []
        for start in stride(from: 0, to: bytes.count, by: 7) {
            updates += tracker.consume(Data(bytes[start..<min(start + 7, bytes.count)]))
        }
        updates += tracker.finish()
        var previous: Int64 = 0
        for update in updates {
            guard let completed = update.completedBytes, let total = update.totalBytes else { throw TestFailure("Byte totals missing") }
            try expect(completed >= previous && completed <= total, "Aggregate counters reset at a file boundary or double-counted completion")
            try expect(abs((update.fraction ?? -1) - Double(completed) / Double(total)) < 0.000001,
                       "Percentage describes one file rather than the aggregate bytes")
            previous = completed
        }
        try expect(updates.contains { $0.currentFile == "folder/a file.bin" && $0.completedBytes == 294_912 },
                   "Second file counter omitted the first file's completed bytes")
        try expect(updates.last?.completedBytes == 327_683 && updates.last?.fraction == 1, "Upload totals are inaccurate")
    }

    @Test
    func testLocalByteTotalsExcludeSymlinkTargets() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            let file = source.appendingPathComponent("item"), nested = source.appendingPathComponent("folder")
            try Data(repeating: 65, count: 700_000).write(to: file); try mkdir(nested)
            try write("abc", to: nested.appendingPathComponent("nested"))
            let outside = root.appendingPathComponent("outside")
            try Data(repeating: 65, count: 1_000_000).write(to: outside)
            try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("link").path, withDestinationPath: outside.path)
            try expect(try DropService.sourceByteCount([file.path, nested.path], control: DropTaskControl()) == 700_003,
                       "Upload preflight counted a symlink target's contents")
            var updates: [DropProgress] = []
            _ = try DropService.copyLocal([file.path, nested.path], directory: destination.path, progress: { updates.append($0) })
            let bytes = updates.compactMap(\.completedBytes)
            try expect(bytes == bytes.sorted() && bytes.last == 700_003, "Local byte progress omitted or reset copied content")
            try expect(updates.filter { $0.completedBytes != nil }.allSatisfy { $0.totalBytes == 700_003 },
                       "Local byte denominator changed across files")
        }
    }

    @Test
    func testNativeRsyncOutputProducesAggregateBytes() throws {
        try temporary { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try mkdir(source); try mkdir(destination)
            try write("abc", to: source.appendingPathComponent("sent unusual name.txt"))
            try write("12345", to: source.appendingPathComponent("z file.txt"))
            var tracker = RemoteProgressTracker(totalBytes: 8, totalFiles: 1)
            var updates: [DropProgress] = []
            _ = try DropService.runControlled(["/usr/bin/rsync", "-rlt", "--progress", "--out-format=REX-DROP:%n", "--", source.path, destination.path + "/"],
                                             10, nil, output: { updates += tracker.consume($0) })
            try expect(updates.contains { $0.completedBytes == 3 } && updates.contains { $0.completedBytes == 8 },
                       "Installed macOS rsync format did not produce real cumulative counters")
            try expect(updates.compactMap(\.completedBytes) == updates.compactMap(\.completedBytes).sorted(),
                       "Installed rsync counters reset across files")
            updates += tracker.finish()
            try expect(updates.last?.totalBytes == 8 && updates.last?.fraction == 1, "Native upload progress failed to complete")
            var empty = RemoteProgressTracker(totalBytes: 0, totalFiles: 1)
            _ = empty.consume(Data("REX-DROP:empty\n0 100% 0.00KB/s 00:00:00\n".utf8))
            try expect(empty.finish().last?.completedBytes == 0 && empty.finish().last?.fraction == 1,
                       "Zero-length uploads did not finish with valid counters")
        }
    }
}
