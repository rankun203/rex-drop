import Foundation

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
}
