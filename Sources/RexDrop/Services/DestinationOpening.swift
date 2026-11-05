import Foundation
import Darwin

extension DropService {
    func destinationToOpen(_ target: [String: Any]) throws -> [String: Any] {
        try control.checkpoint()
        let (current, internalData) = try revalidate(target)
        if current["kind"] as? String == "local", let directory = internalData["cwd"] as? String {
            return ["kind": "local", "directory": directory]
        }
        if current["kind"] as? String == "ssh", let args = internalData["ssh_args"] as? [String],
           let session = internalData["session"] as? String {
            // Recovered connection options belong to this explicit open action,
            // rather than the public rows used for destination discovery.
            return ["kind": "ssh", "directory": "/tmp", "session_id": session, "ssh_args": args]
        }
        throw DropFailure("The selected destination is unavailable. Refresh destinations and try again.")
    }

    func openRemoteDestination(_ metadata: [String: Any]) throws {
        guard metadata["kind"] as? String == "ssh",
              let directory = metadata["directory"] as? String,
              (directory == "/tmp" || Self.matches(directory, "^/tmp/rex-drop\\.[A-Za-z0-9]{8}$")),
              let sid = metadata["session_id"] as? String, sid.hasPrefix("session:"), !Self.hasControls(sid),
              let args = metadata["ssh_args"] as? [String], !args.isEmpty,
              Self.parseSSH(args) == args else {
            throw DropFailure("The SSH destination is unavailable.")
        }
        // An interactive shell keeps the listed upload directory as its cwd;
        // a login shell could reset it to the remote home directory.
        let script = "cd " + Self.shellQuote(directory) + " && ls -ltr && exec \"${SHELL:-/bin/sh}\" -i"
        let remoteCommand = "exec /bin/sh -c " + Self.shellQuote(script)
        let interactiveOptions = ["ConnectTimeout=10", "RemoteCommand=none", "SessionType=default",
                                  "StdinNull=no", "ForkAfterAuthentication=no", "ClearAllForwardings=yes",
                                  "PermitLocalCommand=no"].flatMap { ["-o", $0] }
        let command = [try rexBinary(), "--autostart=false", "window", "new", "-s", sid,
                       directory == "/tmp" ? "Remote /tmp" : "Uploaded files", "--shell=none", "--keep-open", "--json", "--", Self.ssh, "-t"] +
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
