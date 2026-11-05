import Foundation
import Darwin

extension DropService {
    func transfer(_ request: [String: Any]) throws -> [String: Any] {
        try control.checkpoint()
        guard let requested = request["target"] as? [String: Any], let input = request["paths"] as? [String] else {
            throw DropFailure("A selected target and dropped paths are required.")
        }
        let collisionPolicy = CollisionPolicy(rawValue: request["collision_policy"] as? String ?? "ask") ?? .ask
        let paths = try Self.validateSources(input, allowDuplicateBasenames: collisionPolicy == .keepBoth)
        progress(DropProgress(phase: "Checking target", currentFile: "", completedFiles: 0, totalFiles: paths.count, fraction: nil))
        let (target, internalData) = try revalidate(requested)
        let destinations: [String]
        var completionCount = paths.count
        if target["kind"] as? String == "local", let cwd = internalData["cwd"] as? String {
            destinations = try Self.copyLocal(paths, directory: cwd, control: control, progress: { event in
                completionCount = event.totalFiles
                self.progress(event)
            }, collisionPolicy: collisionPolicy)
        } else if let args = internalData["ssh_args"] as? [String] {
            _ = try Self.validateSources(input)
            destinations = try copyRemote(paths, args: args)
        }
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
        var openDestination: [String: Any] = ["kind": target["kind"] ?? "local", "paths": destinations,
            "directory": destinations.first.map { ($0 as NSString).deletingLastPathComponent } ?? ""]
        if let args = internalData["ssh_args"] as? [String], let sid = target["session_id"] as? String {
            // Connection options stay in this completed task's runtime result.
            // They are never included in public destination discovery metadata.
            openDestination["ssh_args"] = args
            openDestination["session_id"] = sid
        }
        return ["ok": true, "paths": destinations, "open_destination": openDestination,
                "message": "Copied and inserted \(paths.count) path(s)."]
    }

    func openRemoteDestination(_ metadata: [String: Any]) throws {
        guard metadata["kind"] as? String == "ssh",
              let directory = metadata["directory"] as? String,
              Self.matches(directory, "^/tmp/rex-drop\\.[A-Za-z0-9]{8}$"),
              let sid = metadata["session_id"] as? String, sid.hasPrefix("session:"), !Self.hasControls(sid),
              let args = metadata["ssh_args"] as? [String], !args.isEmpty,
              Self.parseSSH(args) == args else {
            throw DropFailure("The completed transfer's SSH destination is unavailable.")
        }
        // An interactive shell keeps the listed upload directory as its cwd;
        // a login shell could reset it to the remote home directory.
        let script = "cd " + Self.shellQuote(directory) + " && ls -ltr && exec \"${SHELL:-/bin/sh}\" -i"
        let remoteCommand = "exec /bin/sh -c " + Self.shellQuote(script)
        let interactiveOptions = ["ConnectTimeout=10", "RemoteCommand=none", "SessionType=default",
                                  "StdinNull=no", "ForkAfterAuthentication=no", "ClearAllForwardings=yes",
                                  "PermitLocalCommand=no"].flatMap { ["-o", $0] }
        let command = [try rexBinary(), "--autostart=false", "window", "new", "-s", sid,
                       "Uploaded files", "--shell=none", "--keep-open", "--json", "--", Self.ssh, "-t"] +
            interactiveOptions + args + [remoteCommand]
        let created = try execute(command, 15, Self.localEnvironment())
        guard let window = (try? JSONSerialization.jsonObject(with: created)) as? [String: Any],
              let wid = window["window_id"] as? String,
              let clientsData = try? execute([rexBinary(), "--autostart=false", "client", "ls", "--json"], 15, Self.localEnvironment()),
              let object = (try? JSONSerialization.jsonObject(with: clientsData)) as? [String: Any],
              let clients = object["clients"] as? [[String: Any]] else { return }
        let localApps = clients.filter { client in
            guard let info = client["info"] as? [String: Any], let principal = client["principal"] as? [String: Any] else { return false }
            return info["kind"] as? String == "app" && info["platform"] as? String == "macos" &&
                principal["transport"] as? String == "unix" && (principal["uid"] as? NSNumber)?.uint32Value == getuid() &&
                client["connection_state"] as? String == "connected"
        }
        // Selecting a client is safe only when one local Mac app is identified.
        // The created tab remains in the original session if clients are ambiguous.
        if localApps.count == 1, let client = localApps.first?["client_id"] as? String {
            _ = try execute([rexBinary(), "--autostart=false", "-C", client, "do", "session.select",
                             "session_id=" + sid, "window_id=" + wid], 15, Self.localEnvironment())
        }
    }
}
