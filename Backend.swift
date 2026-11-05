import Foundation
import Darwin
import CryptoKit

struct DropFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DropProgress {
    let phase: String
    let currentFile: String
    let completedFiles: Int
    let totalFiles: Int
    let fraction: Double?
}

final class DropTaskControl {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    var isPaused: Bool { condition.lock(); defer { condition.unlock() }; return paused }
    func pause() {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled else { return }
        paused = true
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGSTOP) }
    }
    func resume() {
        condition.lock(); defer { condition.unlock() }
        paused = false
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGCONT) }
        condition.broadcast()
    }
    func cancel() {
        condition.lock()
        cancelled = true; paused = false
        let running = process
        if let running, running.isRunning {
            Darwin.kill(running.processIdentifier, SIGCONT)
            running.terminate()
        }
        condition.broadcast(); condition.unlock()
        if let running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
    func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled { throw DropFailure("Transfer cancelled. Partial copies may remain.") }
    }
    fileprivate func register(_ process: Process) throws {
        condition.lock(); defer { condition.unlock() }
        self.process = process
        if cancelled {
            if process.isRunning { process.terminate() }
            throw DropFailure("Transfer cancelled. Partial copies may remain.")
        }
        if paused && process.isRunning { Darwin.kill(process.processIdentifier, SIGSTOP) }
    }
    fileprivate func unregister(_ process: Process) {
        condition.lock(); defer { condition.unlock() }
        if self.process === process { self.process = nil }
    }
}

enum DropBackend {
    static func targets() throws -> [[String: Any]] { try DropService().targets() }
    static func transfer(_ request: [String: Any]) throws -> [String: Any] { try DropService().transfer(request) }
}

final class DropService {
    typealias Runner = ([String], TimeInterval, [String: String]?) throws -> Data
    let runner: Runner?
    let rexPath: String?
    let control: DropTaskControl
    let progress: (DropProgress) -> Void
    let startReader: (Int32) throws -> String
    let argvReader: (Int32) throws -> [String]
    static let ssh = "/usr/bin/ssh"
    static let rsync = "/usr/bin/rsync"
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]
    static let agents: Set<String> = ["codex", "claude", "claude-code", "aider", "opencode", "amp"]
    static let overrides = ["BatchMode=yes", "ConnectTimeout=10", "RequestTTY=no", "RemoteCommand=none",
                            "SessionType=default", "StdinNull=no", "ForkAfterAuthentication=no",
                            "ClearAllForwardings=yes", "PermitLocalCommand=no"]
    static let safeConfig: Set<String> = Set(("addressfamily batchmode bindaddress bindinterface canonicaldomains " +
        "canonicalizehostname canonicalizemaxdots canonicalizefallbacklocal certificatefile checkhostip ciphers compression " +
        "connecttimeout connectionattempts controlmaster controlpath controlpersist globalknownhostsfile hostkeyalias " +
        "hostkeyalgorithms hostname identitiesonly identityagent identityfile ipqos kexalgorithms loglevel macs " +
        "passwordauthentication pkcs11provider port preferredauthentications proxycommand proxyjump pubkeyacceptedalgorithms " +
        "pubkeyauthentication securitykeyprovider serveralivecountmax serveraliveinterval stricthostkeychecking " +
        "tcpkeepalive user userknownhostsfile verifyhostkeydns").split(separator: " ").map(String.init))

    init(runner: Runner? = nil, rexPath: String? = nil,
         processStart: ((Int32) throws -> String)? = nil,
         processArgv: ((Int32) throws -> [String])? = nil,
         control: DropTaskControl = DropTaskControl(), progress: @escaping (DropProgress) -> Void = { _ in }) {
        self.runner = runner; self.rexPath = rexPath
        self.control = control
        let eventLock = NSLock()
        var lastEvent = Date.distantPast, lastPhase = "", lastFile = ""
        self.progress = { event in
            eventLock.lock()
            let now = Date()
            let emit = event.phase != lastPhase || event.currentFile != lastFile ||
                now.timeIntervalSince(lastEvent) >= 0.1 ||
                (event.totalFiles > 0 && event.completedFiles == event.totalFiles)
            if emit { lastEvent = now; lastPhase = event.phase; lastFile = event.currentFile }
            eventLock.unlock()
            if emit { progress(event) }
        }
        self.startReader = processStart ?? DropService.processStart
        self.argvReader = processArgv ?? DropService.processArgv
    }

    static func localEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("REX") }
    }

    static func run(_ command: [String], _ timeout: TimeInterval = 15,
                    _ environment: [String: String]? = nil) throws -> Data {
        try runControlled(command, timeout, environment)
    }

    func execute(_ command: [String], _ timeout: TimeInterval = 15, _ environment: [String: String]? = nil,
                 output: ((Data) -> Void)? = nil) throws -> Data {
        try control.checkpoint()
        let result: Data
        if let runner { result = try runner(command, timeout, environment) }
        else { result = try Self.runControlled(command, timeout, environment, control: control, output: output) }
        try control.checkpoint()
        return result
    }

    static func runControlled(_ command: [String], _ timeout: TimeInterval,
                              _ environment: [String: String]?, control: DropTaskControl? = nil,
                              output observer: ((Data) -> Void)? = nil) throws -> Data {
        try control?.checkpoint()
        guard let executable = command.first else { throw DropFailure("Required command is missing.") }
        let process = Process(), output = Pipe(), errors = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw DropFailure("Required command could not start.") }
        do { try control?.register(process) } catch {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        defer { control?.unregister(process) }
        // Poll both pipes without blocking. Proxy subprocesses can retain pipe
        // descriptors after SSH exits, so EOF also has a bounded grace period.
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        defer { for handle in handles { try? handle.close() } }
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0) }
        for descriptor in descriptors { _ = fcntl(descriptor.fd, F_SETFL, fcntl(descriptor.fd, F_GETFL) | O_NONBLOCK) }
        var data = Data(), tooLarge = false, eof = [false, false], endedAt: Date?
        var activeElapsed: TimeInterval = 0
        var lastTick = Date()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if control?.isCancelled == true {
                process.terminate()
                if done.wait(timeout: .now() + 1) == .timedOut { Darwin.kill(process.processIdentifier, SIGKILL) }
                throw DropFailure("Transfer cancelled. Partial copies may remain.")
            }
            let now = Date()
            if control?.isPaused != true { activeElapsed += now.timeIntervalSince(lastTick) }
            lastTick = now
            if endedAt == nil && done.wait(timeout: .now()) == .success { endedAt = Date() }
            if endedAt != nil && eof.allSatisfy({ $0 }) { break }
            if let endedAt, Date().timeIntervalSince(endedAt) > 2 {
                throw DropFailure("Command output did not finish. Check the selected connection.")
            }
            if endedAt == nil && activeElapsed >= timeout {
                process.terminate()
                if done.wait(timeout: .now() + 1) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 1)
                }
                throw DropFailure("Operation timed out. Check the selected pane and connection.")
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            for index in descriptors.indices where !eof[index] {
                // Bound each drain batch so continuous output still reaches
                // timeout checks and the other descriptor promptly.
                for _ in 0..<16 {
                    let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                    if count == 0 { eof[index] = true; descriptors[index].fd = -1; break }
                    if count < 0 { break }
                    if index == 0 {
                        observer?(Data(buffer.prefix(count)))
                        if data.count + count <= 8 * 1024 * 1024 { data.append(contentsOf: buffer.prefix(count)) }
                        else if observer == nil { tooLarge = true }
                    }
                }
            }
        }
        guard process.terminationStatus == 0 else {
            // SSH stderr may contain private arguments and paths.
            throw DropFailure("Command failed. Check Rex, SSH authentication, and remote rsync availability.")
        }
        guard !tooLarge else { throw DropFailure("Command returned too much output.") }
        return data
    }

    func rexBinary() throws -> String {
        if let rexPath { return rexPath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
                          "/Applications/Rex.app/Contents/MacOS/rex"]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(String(directory) + "/rex")
        }
        guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DropFailure("Rex CLI unavailable. Open the local Rex app first.")
        }
        return result
    }

    func api(_ method: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        let output = try execute([rexBinary(), "--autostart=false", "api", "call", method,
                                 String(decoding: data, as: UTF8.self)], 15, Self.localEnvironment())
        guard let value = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw DropFailure("Rex returned an invalid API response.")
        }
        return value
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func destinationDigest(_ fields: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func sshDestination(_ args: [String]) -> (key: String, name: String)? {
        // -G evaluates the connection configuration without opening a session.
        // Disable hostname canonicalization to keep this lookup free of DNS.
        let command = [Self.ssh, "-G", "-o", "CanonicalizeHostname=no"] + Self.sshCommand(args).dropFirst()
        guard let data = try? execute(command, 5, nil), let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        let wanted: Set<String> = ["hostname", "user", "port", "proxyjump", "proxycommand"]
        for line in text.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, wanted.contains(String(parts[0])) else { continue }
            fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        guard let rawHost = fields["hostname"], let user = fields["user"],
              Self.matches(rawHost, "^[A-Za-z0-9_][A-Za-z0-9_.:%\\[\\]-]*$"),
              !user.isEmpty, !Self.hasControls(user), !user.contains(where: { $0.isWhitespace }),
              let port = Int(fields["port"] ?? ""), (1...65535).contains(port) else { return nil }
        let host = rawHost.lowercased()
        let routes = ["proxyjump", "proxycommand"].map { key -> String in
            let value = fields[key] ?? "none"
            return value == "none" ? "" : value
        }
        // Proxy commands can contain credentials. Only their digest reaches UI
        // metadata; distinct routes remain conservatively separate destinations.
        let key = Self.destinationDigest(["ssh", host, user, String(port)] + routes)
        let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        return (key, user + "@" + displayHost + (port == 22 ? "" : ":" + String(port)))
    }

    // Small POSIX word splitter for inspecting remote commands, never executing
    // them. Unbalanced quotes and explicit second SSH hops disable targeting.
    static func shellWords(_ value: String) -> [String]? {
        var result: [String] = [], word = "", quote: Character?, escape = false, active = false
        for char in value {
            if escape { word.append(char); escape = false; active = true; continue }
            if char == "\\" && quote != "'" { escape = true; active = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { word.append(char) }
                active = true
            } else if char == "'" || char == "\"" { quote = char; active = true }
            else if char.isWhitespace {
                if active { result.append(word); word = ""; active = false }
            } else { word.append(char); active = true }
        }
        guard quote == nil && !escape else { return nil }
        if active { result.append(word) }
        return result
    }

    static func parseSSH(_ argv: [String]) -> [String]? {
        let operands = Set("BbcDEeFIiJLlmopRSWw"), preserve = Set("BbcFIiJlmopS")
        let flags = Set("46AaCKkqvXxYytT"), drop = Set("AaXxYytT")
        var options: [String] = [], index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" { index += 1; break }
            if !arg.hasPrefix("-") || arg == "-" { break }
            let chars = Array(arg.dropFirst())
            guard !chars.isEmpty else { return nil }
            var cursor = 0
            while cursor < chars.count {
                let flag = chars[cursor]
                if operands.contains(flag) {
                    var value = String(chars.dropFirst(cursor + 1))
                    if value.isEmpty { index += 1; guard index < argv.count else { return nil }; value = argv[index] }
                    if flag == "o" {
                        let key = value.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
                        guard safeConfig.contains(key) else { return nil }
                    }
                    if flag == "W" { return nil }
                    if preserve.contains(flag) { options += ["-" + String(flag), value] }
                    break
                }
                guard flags.contains(flag) else { return nil }
                if !drop.contains(flag) { options.append("-" + String(flag)) }
                cursor += 1
            }
            index += 1
        }
        guard index < argv.count, matches(argv[index], "^[A-Za-z0-9_][A-Za-z0-9_.@:%\\[\\]-]*$"),
              let remote = shellWords(argv.dropFirst(index + 1).joined(separator: " ")),
              !remote.contains(where: { ($0 as NSString).lastPathComponent == "ssh" }) else { return nil }
        return options + [argv[index]]
    }

    static func processArgv(_ pid: Int32) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 8, size <= 16 * 1024 * 1024 else {
            throw DropFailure("Cannot inspect this SSH process. Refresh and try again.")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else {
            throw DropFailure("SSH process changed during inspection.")
        }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc <= 65536, let executableEnd = bytes[4..<size].firstIndex(of: 0) else {
            throw DropFailure("Invalid SSH process arguments.")
        }
        var start = executableEnd + 1
        while start < size && bytes[start] == 0 { start += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            guard start < size, let end = bytes[start..<size].firstIndex(of: 0),
                  let word = String(bytes: bytes[start..<end], encoding: .utf8) else {
                throw DropFailure("Incomplete or unsupported SSH process arguments.")
            }
            result.append(word); start = end + 1
        }
        return result
    }

    static func processStart(_ pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else {
            throw DropFailure("Selected process has exited or cannot be inspected.")
        }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    static func blocks(in value: Any) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            var result = object["block_id"] != nil && object["host_id"] != nil ? [object] : []
            for (key, child) in object where key != "layout" { result += blocks(in: child) }
            return result
        }
        if let array = value as? [Any] { return array.flatMap { blocks(in: $0) } }
        return []
    }

    func inspect(_ session: [String: Any], _ block: [String: Any], _ status: [String: Any]) throws -> ([String: Any], [String: Any]?) {
        guard let sid = session["session_id"] as? String, let bid = block["block_id"] as? String else {
            throw DropFailure("Rex returned an invalid pane identity.")
        }
        var target: [String: Any] = ["id": sid + "/" + bid, "session_id": sid, "block_id": bid,
            "label": (session["label"] as? String ?? sid) + " · " + (block["label"] as? String ?? "terminal") + " [" + bid.suffix(8) + "]",
            "kind": "unsupported", "detail": "", "selectable": false]
        guard let host = status["host_id"] as? String, block["host_id"] as? String == host else {
            target["detail"] = "Remote Rex server pane: select a local shell or local SSH pane."
            return (target, nil)
        }
        do {
            let process = try api("com.superlogical.terminal.process", ["session_id": sid, "block_id": bid, "args": [:]])
            let fg = process["foreground"] as? [String: Any] ?? [:]
            let name = ((fg["name"] as? String ?? "") as NSString).lastPathComponent.drop(while: { $0 == "-" }).description
            guard let number = fg["pid"] as? NSNumber, number.int64Value > 0, number.int64Value <= Int32.max else {
                throw DropFailure("This pane has no foreground process.")
            }
            let pid = number.int32Value
            var internalData: [String: Any] = ["pid": pid, "start": try startReader(pid), "name": name,
                "path": fg["path"] ?? NSNull(), "argv0": fg["argv0"] ?? NSNull(), "host": host,
                "instance": status["instance_id"] ?? NSNull(), "session": sid, "block": bid]
            if name == "ssh" {
                let argv = try argvReader(pid)
                guard let executable = argv.first, (executable as NSString).lastPathComponent == "ssh",
                      let options = Self.parseSSH(Array(argv.dropFirst())), let destination = options.last else {
                    throw DropFailure("Unsupported or changed SSH invocation. Use an ordinary interactive SSH connection.")
                }
                internalData["argv"] = argv; internalData["ssh_args"] = options
                target["kind"] = "ssh"; target["detail"] = "SSH " + destination + " · private /tmp directory"
                target["display_name"] = destination
                target["destination_key"] = Self.destinationDigest(["ssh-arguments"] + options)
            } else if Self.shells.union(Self.agents).contains(name), let cwd = fg["cwd"] as? String, cwd.hasPrefix("/") {
                let canonical = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
                internalData["cwd"] = canonical; target["kind"] = "local"
                target["detail"] = (Self.agents.contains(name) ? name + " · " : "") + canonical
                target["display_name"] = canonical == "/" ? "/" : (canonical as NSString).lastPathComponent
                target["destination_key"] = Self.destinationDigest(["local", canonical])
            } else {
                throw DropFailure("Foreground process: " + (name.isEmpty ? "unknown" : name) + ". Return this pane to its shell.")
            }
            let data = try JSONSerialization.data(withJSONObject: internalData, options: [.sortedKeys])
            target["fingerprint"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            target["selectable"] = true
            return (target, internalData)
        } catch {
            target["detail"] = (error as? DropFailure)?.message ?? "Pane inspection failed. Refresh targets."
            return (target, nil)
        }
    }

    func enumerate() throws -> ([[String: Any]], [String: [String: Any]]) {
        let status = try api("server.status")
        guard status["host_id"] as? String != nil else { throw DropFailure("Local Rex server identity is unavailable.") }
        let sessions = try api("session.list")["sessions"] as? [[String: Any]] ?? []
        var targets: [[String: Any]] = [], internals: [String: [String: Any]] = [:]
        for session in sessions {
            guard let sid = session["session_id"] as? String else { continue }
            let view = try api("session.view", ["session_id": sid])
            let activeWindow = (view["windows"] as? [[String: Any]] ?? []).first {
                ($0["window_id"] as? String) == (view["active_window_id"] as? String)
            }
            let focusedBlock = activeWindow?["focused_block_id"] as? String
            var seen: Set<String> = []
            for block in Self.blocks(in: view) {
                guard let bid = block["block_id"] as? String, seen.insert(bid).inserted else { continue }
                var (target, internalData) = try inspect(session, block, status)
                target["_preferred"] = bid == focusedBlock
                targets.append(target)
                if let internalData, let id = target["id"] as? String { internals[id] = internalData }
            }
        }
        return (targets, internals)
    }

    func targets() throws -> [[String: Any]] {
        let (all, internals) = try enumerate()
        var byDestination: [String: [String: Any]] = [:]
        var sshCache: [String: (key: String, name: String)] = [:]
        var failedLookups: Set<String> = []
        for var target in all where target["selectable"] as? Bool == true {
            guard let id = target["id"] as? String else { continue }
            if target["kind"] as? String == "ssh", let args = internals[id]?["ssh_args"] as? [String] {
                let cacheKey = Self.destinationDigest(args)
                if sshCache[cacheKey] == nil && !failedLookups.contains(cacheKey) {
                    if let destination = sshDestination(args) { sshCache[cacheKey] = destination }
                    else { failedLookups.insert(cacheKey) }
                }
                if let destination = sshCache[cacheKey] {
                    target["destination_key"] = destination.key
                    target["display_name"] = destination.name
                    target["detail"] = "SSH · private /tmp directory"
                }
            }
            guard let key = target["destination_key"] as? String else { continue }
            if let current = byDestination[key] {
                let preferred = target["_preferred"] as? Bool == true
                let currentPreferred = current["_preferred"] as? Bool == true
                if preferred != currentPreferred {
                    if preferred { byDestination[key] = target }
                } else if id < (current["id"] as? String ?? "") { byDestination[key] = target }
            } else { byDestination[key] = target }
        }
        return byDestination.values.map { target in
            var row = target; row.removeValue(forKey: "_preferred"); return row
        }.sorted { lhs, rhs in
            let leftSSH = lhs["kind"] as? String == "ssh", rightSSH = rhs["kind"] as? String == "ssh"
            if leftSSH != rightSSH { return leftSSH }
            let order = (lhs["display_name"] as? String ?? "").localizedCaseInsensitiveCompare(rhs["display_name"] as? String ?? "")
            return order == .orderedSame ? (lhs["id"] as? String ?? "") < (rhs["id"] as? String ?? "") : order == .orderedAscending
        }
    }

    func revalidate(_ target: [String: Any]) throws -> ([String: Any], [String: Any]) {
        let (targets, internals) = try enumerate()
        for current in targets where current["selectable"] as? Bool == true {
            if ["id", "session_id", "block_id", "fingerprint"].allSatisfy({ key in
                guard let value = target[key] as? String else { return false }
                return current[key] as? String == value
            }), let id = current["id"] as? String, let internalData = internals[id] { return (current, internalData) }
        }
        throw DropFailure("Selected pane or foreground process changed. Refresh and choose it again.")
    }

    static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 32 || ($0.value >= 127 && $0.value <= 159) }
    }

    static func info(_ path: String) -> stat? {
        var value = stat()
        return lstat(path, &value) == 0 ? value : nil
    }

    static func validateSources(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { throw DropFailure("Choose one or more files or folders.") }
        var result: [String] = [], names: Set<String> = []
        for value in paths {
            guard value.hasPrefix("/"), !hasControls(value) else {
                throw DropFailure("Each dropped item must have an absolute path without control characters.")
            }
            let path = (value as NSString).standardizingPath
            let name = (path as NSString).lastPathComponent
            guard let status = info(path), (status.st_mode & S_IFMT == S_IFREG || status.st_mode & S_IFMT == S_IFDIR), path != "/" else {
                throw DropFailure("Choose regular files and folders; root symlinks and devices are unsupported.")
            }
            guard names.insert(name).inserted else { throw DropFailure("Dropped items have duplicate basenames. Transfer them separately.") }
            result.append(path)
        }
        return result
    }

    static func copyLocal(_ paths: [String], directory: String,
                          control: DropTaskControl = DropTaskControl(),
                          progress: @escaping (DropProgress) -> Void = { _ in }) throws -> [String] {
        try control.checkpoint()
        let manager = FileManager.default, root = URL(fileURLWithPath: directory).standardizedFileURL
        guard !hasControls(directory), let rootInfo = info(root.path), rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw DropFailure("The shell directory is unavailable or contains control characters.")
        }
        let realRoot = root.resolvingSymlinksInPath().path
        for path in paths where info(path).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true {
            let realSource = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if realRoot == realSource || realRoot.hasPrefix(realSource + "/") {
                throw DropFailure("A folder cannot be copied into itself or one of its descendants.")
            }
        }
        let destinations = paths.map { root.appendingPathComponent(($0 as NSString).lastPathComponent).path }
        guard !destinations.contains(where: { info($0) != nil }) else {
            throw DropFailure("A destination basename already exists. Rename the item or change shell directory.")
        }
        var totalBytes: Int64 = 0, totalFiles = 0, completedBytes: Int64 = 0, completedFiles = 0
        func scan(_ path: String) throws {
            try control.checkpoint()
            guard let metadata = info(path) else { throw DropFailure("A dropped item became unavailable.") }
            let kind = metadata.st_mode & S_IFMT
            guard [S_IFREG, S_IFDIR, S_IFLNK].contains(kind) else {
                throw DropFailure("Folders may contain only regular files, directories, and symlinks.")
            }
            totalFiles += 1
            if kind == S_IFREG { totalBytes += max(0, metadata.st_size) }
            if kind == S_IFDIR {
                for name in try manager.contentsOfDirectory(atPath: path).sorted() {
                    try scan((path as NSString).appendingPathComponent(name))
                }
            }
        }
        progress(DropProgress(phase: "Preparing", currentFile: "", completedFiles: 0, totalFiles: 0, fraction: nil))
        for path in paths { try scan(path) }
        func report(_ path: String) {
            let fraction = totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) :
                (totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0)
            progress(DropProgress(phase: "Copying", currentFile: (path as NSString).lastPathComponent,
                                  completedFiles: completedFiles, totalFiles: totalFiles, fraction: fraction))
        }
        func copy(_ source: String, _ destination: String) throws {
            try control.checkpoint()
            guard let metadata = info(source) else { throw DropFailure("A dropped item became unavailable.") }
            report(source)
            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFLNK {
                try manager.createSymbolicLink(atPath: destination, withDestinationPath: manager.destinationOfSymbolicLink(atPath: source))
            } else if kind == S_IFDIR {
                try manager.createDirectory(atPath: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for name in try manager.contentsOfDirectory(atPath: source).sorted() {
                    try copy((source as NSString).appendingPathComponent(name), (destination as NSString).appendingPathComponent(name))
                }
            } else if kind == S_IFREG {
                let input = Darwin.open(source, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                guard input >= 0 else { throw DropFailure("Could not open a dropped file.") }
                defer { Darwin.close(input) }
                var opened = stat()
                guard fstat(input, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
                    throw DropFailure("A dropped file changed during transfer.")
                }
                let output = Darwin.open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw DropFailure("Could not stage a dropped file.") }
                defer { Darwin.close(output) }
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                while true {
                    try control.checkpoint()
                    let count = Darwin.read(input, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw DropFailure("Could not read a dropped file.")
                    }
                    var offset = 0
                    while offset < count {
                        try control.checkpoint()
                        let written = buffer.withUnsafeBytes { bytes in
                            Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        }
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw DropFailure("Could not write a dropped file. Check available space.") }
                        offset += written; completedBytes += Int64(written)
                    }
                    report(source)
                }
            } else { throw DropFailure("A dropped folder contains an unsupported device or special file.") }
            if kind != S_IFLNK {
                try manager.setAttributes([.posixPermissions: Int(metadata.st_mode & 0o777),
                    .modificationDate: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)],
                    ofItemAtPath: destination)
            }
            completedFiles += 1; report(source)
        }
        let stage = root.appendingPathComponent(".rex-drop-" + UUID().uuidString)
        do { try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw DropFailure("Cannot create a staging directory in the shell directory.") }
        defer { try? manager.removeItem(at: stage) }
        do {
            for path in paths { try copy(path, stage.appendingPathComponent((path as NSString).lastPathComponent).path) }
        } catch {
            if control.isCancelled { throw DropFailure("Transfer cancelled. Partial copies may remain.") }
            throw (error as? DropFailure) ?? DropFailure("Could not read or stage a dropped item. Check file permissions and available space.")
        }
        for destination in destinations {
            try control.checkpoint()
            let staged = stage.appendingPathComponent((destination as NSString).lastPathComponent).path
            // Same-volume atomic publication rejects even race-time collisions.
            guard renamex_np(staged, destination, UInt32(RENAME_EXCL)) == 0 else {
                throw DropFailure("Local copy failed or a basename appeared. Partial copies may remain in the shell directory.")
            }
        }
        return destinations
    }

    static func sshCommand(_ args: [String]) -> [String] {
        [ssh] + overrides.flatMap { ["-o", $0] } + args
    }

    func copyRemote(_ paths: [String], args: [String]) throws -> [String] {
        guard let host = args.last else { throw DropFailure("SSH destination is missing.") }
        try control.checkpoint()
        progress(DropProgress(phase: "Connecting", currentFile: "", completedFiles: 0, totalFiles: paths.count, fraction: nil))
        let setup = "command -v rsync >/dev/null 2>&1 || exit 127; umask 077; mktemp -d /tmp/rex-drop.XXXXXXXX"
        let data = try execute(Self.sshCommand(args) + [setup], 30, nil)
        guard let output = String(data: data, encoding: .utf8) else { throw DropFailure("SSH returned an invalid temporary path.") }
        let directory = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.matches(directory, "^/tmp/rex-drop\\.[A-Za-z0-9]{8}$") else {
            throw DropFailure("SSH returned an unexpected temporary path. Nothing was inserted.")
        }
        let transport = Self.sshCommand(Array(args.dropLast())).map(Self.shellQuote).joined(separator: " ")
        var pending = Data(), currentFile = ((paths.first ?? "") as NSString).lastPathComponent
        func record(_ bytes: Data) {
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if words.count >= 2, words[1].hasSuffix("%"), let percent = Double(words[1].dropLast()) {
                // Classic rsync reports a percentage of the current file.
                progress(DropProgress(phase: "Uploading file", currentFile: currentFile,
                                      completedFiles: 0, totalFiles: paths.count, fraction: max(0, min(1, percent / 100))))
            } else if !line.hasPrefix("sending ") && !line.hasPrefix("sent ") && !line.hasPrefix("total ") && !line.hasPrefix("created ") {
                currentFile = line
                progress(DropProgress(phase: "Uploading", currentFile: currentFile, completedFiles: 0, totalFiles: paths.count, fraction: nil))
            }
        }
        func receive(_ bytes: Data) {
            pending.append(bytes)
            while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                record(Data(pending[..<index])); pending.removeSubrange(...index)
            }
            if pending.count > 65536 { pending.removeAll() }
        }
        do {
            _ = try execute([Self.rsync, "-rlt", "-e", transport, "--progress", "--"] + paths + [host + ":" + directory + "/"], 600, nil, output: receive)
            if !pending.isEmpty { record(pending) }
            progress(DropProgress(phase: "Uploaded", currentFile: currentFile, completedFiles: paths.count, totalFiles: paths.count, fraction: 1))
        } catch {
            if control.isCancelled { throw DropFailure("Transfer cancelled. Partial files may remain in " + directory + ".") }
            throw DropFailure("Remote copy failed. Check SSH and remote rsync. Partial files may remain in " + directory + ".")
        }
        return paths.map { directory + "/" + ($0 as NSString).lastPathComponent }
    }

    func transfer(_ request: [String: Any]) throws -> [String: Any] {
        try control.checkpoint()
        guard let requested = request["target"] as? [String: Any], let input = request["paths"] as? [String] else {
            throw DropFailure("A selected target and dropped paths are required.")
        }
        let paths = try Self.validateSources(input)
        progress(DropProgress(phase: "Checking target", currentFile: "", completedFiles: 0, totalFiles: paths.count, fraction: nil))
        let (target, internalData) = try revalidate(requested)
        let destinations: [String]
        var completionCount = paths.count
        if target["kind"] as? String == "local", let cwd = internalData["cwd"] as? String {
            destinations = try Self.copyLocal(paths, directory: cwd, control: control, progress: { event in
                completionCount = event.totalFiles
                self.progress(event)
            })
        } else if let args = internalData["ssh_args"] as? [String] { destinations = try copyRemote(paths, args: args) }
        else { throw DropFailure("The selected target is unavailable.") }
        do {
            progress(DropProgress(phase: "Inserting paths", currentFile: "", completedFiles: completionCount,
                                  totalFiles: completionCount, fraction: 1))
            try control.checkpoint()
            _ = try revalidate(target)
            guard let sid = target["session_id"] as? String, let bid = target["block_id"] as? String else { throw DropFailure("Pane identity changed.") }
            let text = destinations.map(Self.shellQuote).joined(separator: " ") + " "
            _ = try execute([rexBinary(), "--autostart=false", "send", "-s", sid, "-b", bid, "--", text], 15, Self.localEnvironment())
        } catch {
            throw DropFailure("Files copied, but paths were not inserted: " + ((error as? DropFailure)?.message ?? "Refresh the selected pane."))
        }
        progress(DropProgress(phase: "Complete", currentFile: "", completedFiles: completionCount, totalFiles: completionCount, fraction: 1))
        return ["ok": true, "paths": destinations, "message": "Copied and inserted \(paths.count) path(s)."]
    }
}
