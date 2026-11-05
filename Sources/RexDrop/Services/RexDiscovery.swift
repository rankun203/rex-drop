import Foundation
import CryptoKit

extension DropService {
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]
    static let agents: Set<String> = ["codex", "claude", "claude-code", "aider", "opencode", "amp"]

    static func destinationDigest(_ fields: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                target["destination_path"] = "/tmp"
                target["destination_display"] = destination + ":/tmp"
                target["destination_key"] = Self.destinationDigest(["ssh-arguments"] + options)
            } else if Self.shells.union(Self.agents).contains(name), let cwd = fg["cwd"] as? String, cwd.hasPrefix("/") {
                let canonical = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
                internalData["cwd"] = canonical; target["kind"] = "local"
                target["detail"] = (Self.agents.contains(name) ? name + " · " : "") + canonical
                target["display_name"] = canonical == "/" ? "/" : (canonical as NSString).lastPathComponent
                target["destination_path"] = canonical
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                target["destination_display"] = canonical == home ? "~" : (canonical.hasPrefix(home + "/") ? "~" + canonical.dropFirst(home.count) : canonical)
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
                    target["destination_display"] = destination.name + ":/tmp"
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
}
