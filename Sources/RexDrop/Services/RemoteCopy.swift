import Foundation

extension DropService {
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
}
