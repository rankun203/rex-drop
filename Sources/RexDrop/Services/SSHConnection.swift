import Foundation

extension DropService {
    static let ssh = "/usr/bin/ssh"
    static let rsync = "/usr/bin/rsync"
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

    static func sshCommand(_ args: [String]) -> [String] {
        [ssh] + overrides.flatMap { ["-o", $0] } + args
    }
}
