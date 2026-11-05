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

    func openRemoteDestination(_ metadata: [String: Any], readinessTimeout: TimeInterval = 5) throws {
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
        let rex = try rexBinary()
        let environment = Self.localEnvironment()
        let clientsData = try execute([rex, "--autostart=false", "client", "ls", "--json"], 15, environment)
        let object = try JSONSerialization.jsonObject(with: clientsData) as? [String: Any]
        let clients = object?["clients"] as? [[String: Any]] ?? []
        let localApps = clients.filter { client in
            guard let info = client["info"] as? [String: Any], let principal = client["principal"] as? [String: Any] else { return false }
            return info["kind"] as? String == "app" && info["platform"] as? String == "macos" &&
                principal["transport"] as? String == "unix" && (principal["uid"] as? NSNumber)?.uint32Value == getuid() &&
                client["connection_state"] as? String == "connected"
        }
        guard localApps.count == 1, let client = localApps.first?["client_id"] as? String else {
            throw DropFailure("Open one local Rex app to browse this folder.")
        }
        let previousSessions = Set(localApps.first?["session_ids"] as? [String] ?? [])
        func openSSH(in session: String) throws -> Data {
            try execute([rex, "--autostart=false", "window", "new", "-s", session,
                         directory == "/tmp" ? "Remote /tmp" : "Uploaded files",
                         "--shell=none", "--keep-open", "--json", "--", Self.ssh, "-t"] +
                        interactiveOptions + args + [remoteCommand], 15, environment)
        }
        // Native windows need Remote Control; server-side tabs remain available
        // without it, so folder browsing can still complete in the original session.
        do {
            _ = try execute([rex, "--autostart=false", "-C", client, "do", "client.window.new"], 15, environment)
        } catch {
            _ = try openSSH(in: sid)
            return
        }
        // The client action acknowledges before its native window and default
        // session attach. Wait for that session instead of selecting an unrelated
        // session in the old native window while creation is still in flight.
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, readinessTimeout)
        var ready: (session: String, defaultWindow: String?)?
        repeat {
            try control.checkpoint()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            if let data = try? execute([rex, "--autostart=false", "client", "ls", "--json"], min(1, remaining), environment),
               let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let entries = value["clients"] as? [[String: Any]],
               let current = entries.first(where: { $0["client_id"] as? String == client }) {
                let added = Set(current["session_ids"] as? [String] ?? []).subtracting(previousSessions)
                if added.count > 1 { break }
                if let newSession = added.first, added.count == 1 {
                    let timeLeft = deadline - ProcessInfo.processInfo.systemUptime
                    if timeLeft > 0,
                       let inspected = try? execute([rex, "--autostart=false", "session", "inspect", newSession, "--json"], min(1, timeLeft), environment),
                       let session = (try? JSONSerialization.jsonObject(with: inspected)) as? [String: Any],
                       let windows = session["windows"] as? [[String: Any]], !windows.isEmpty {
                        ready = (newSession, windows.count == 1 ? windows.first?["window_id"] as? String : nil)
                        break
                    }
                }
            }
            let delay = min(0.05, deadline - ProcessInfo.processInfo.systemUptime)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let ready else {
            // An unavailable, late, or ambiguous attachment still gets a useful
            // tab in the original session. Never create a second native window.
            _ = try openSSH(in: sid)
            return
        }
        let created = try openSSH(in: ready.session)
        if let blank = ready.defaultWindow,
           let value = (try? JSONSerialization.jsonObject(with: created)) as? [String: Any],
           let newWindow = value["window_id"] as? String, newWindow != blank {
            _ = try? execute([rex, "--autostart=false", "window", "close", "-s", ready.session, blank], 15, environment)
        }
        _ = try? execute([rex, "--autostart=false", "session", "rename", ready.session, "Rex Drop"], 15, environment)
    }
}
