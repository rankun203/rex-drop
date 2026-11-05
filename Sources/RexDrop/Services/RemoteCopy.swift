import Foundation

/// Classic macOS rsync reports bytes for each file, separated by filename lines.
/// Keep those file counters separate from the task's cumulative content bytes.
struct RemoteProgressTracker {
    let totalFiles: Int
    private(set) var totalBytes: Int64
    private(set) var currentFile: String
    private var pending = Data()
    private var finishedBytes: Int64 = 0
    private var fileBytes: Int64 = 0
    private var fileFinished = false

    init(totalBytes: Int64, totalFiles: Int, currentFile: String = "") {
        self.totalBytes = totalBytes; self.totalFiles = totalFiles; self.currentFile = currentFile
    }

    private var completedBytes: Int64 { finishedBytes + (fileFinished ? 0 : fileBytes) }

    private func event(phase: String = "Uploading", finished: Bool = false) -> DropProgress {
        let completed = finished ? totalBytes : completedBytes
        return DropProgress(phase: phase, currentFile: currentFile, completedFiles: finished ? totalFiles : 0,
                            totalFiles: totalFiles, fraction: finished ? 1 : (totalBytes > 0 ? Double(completed) / Double(totalBytes) : nil),
                            completedBytes: completed, totalBytes: totalBytes)
    }

    private mutating func record(_ data: Data) -> DropProgress? {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("REX-DROP:") {
            // A filename line begins a new file, directory, or symlink. The
            // marker keeps filenames distinct from rsync's numeric records.
            if !fileFinished { finishedBytes += fileBytes }
            fileBytes = 0; fileFinished = false
            currentFile = String(line.dropFirst("REX-DROP:".count))
            return event()
        }
        let words = line.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 4, words[1].hasSuffix("%"),
           let percent = Int(words[1].dropLast()), (0...100).contains(percent),
           let count = Int64(words[0].replacingOccurrences(of: ",", with: "")), count >= 0,
           words[2].contains("/s") {
            if !fileFinished {
                fileBytes = max(fileBytes, count)
                if percent == 100 { finishedBytes += fileBytes; fileFinished = true }
            }
            totalBytes = max(totalBytes, completedBytes)
            return event()
        }
        return nil
    }

    mutating func consume(_ data: Data) -> [DropProgress] {
        pending.append(data)
        var events: [DropProgress] = []
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            if let update = record(Data(pending[..<index])) { events.append(update) }
            pending.removeSubrange(...index)
        }
        if pending.count > 65536 { pending.removeAll() }
        return events
    }

    mutating func finish() -> [DropProgress] {
        var events: [DropProgress] = []
        if !pending.isEmpty, let update = record(pending) { events.append(update) }
        pending.removeAll()
        // Successful rsync exit confirms the full selected content transferred,
        // including zero-length files and entries without progress records.
        events.append(event(phase: "Uploaded", finished: true))
        return events
    }
}

extension DropService {
    func copyRemote(_ paths: [String], args: [String]) throws -> [String] {
        guard let host = args.last else { throw DropFailure("SSH destination is missing.") }
        try control.checkpoint()
        progress(DropProgress(phase: "Preparing", currentFile: "", completedFiles: 0, totalFiles: paths.count, fraction: nil))
        let totalBytes = try Self.sourceByteCount(paths, control: control)
        progress(DropProgress(phase: "Connecting", currentFile: "", completedFiles: 0, totalFiles: paths.count, fraction: nil,
                              completedBytes: 0, totalBytes: totalBytes))
        let setup = "command -v rsync >/dev/null 2>&1 || exit 127; umask 077; mktemp -d /tmp/rex-drop.XXXXXXXX"
        let data = try execute(Self.sshCommand(args) + [setup], 30, nil)
        guard let output = String(data: data, encoding: .utf8) else { throw DropFailure("SSH returned an invalid temporary path.") }
        let directory = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.matches(directory, "^/tmp/rex-drop\\.[A-Za-z0-9]{8}$") else {
            throw DropFailure("SSH returned an unexpected temporary path. Nothing was inserted.")
        }
        let transport = Self.sshCommand(Array(args.dropLast())).map(Self.shellQuote).joined(separator: " ")
        var tracker = RemoteProgressTracker(totalBytes: totalBytes, totalFiles: paths.count,
                                            currentFile: ((paths.first ?? "") as NSString).lastPathComponent)
        func receive(_ bytes: Data) {
            for event in tracker.consume(bytes) { progress(event) }
        }
        do {
            _ = try execute([Self.rsync, "-rlt", "-e", transport, "--progress", "--out-format=REX-DROP:%n", "--"] + paths + [host + ":" + directory + "/"], 600, nil, output: receive)
            for event in tracker.finish() { progress(event) }
        } catch {
            if control.isCancelled { throw DropFailure("Transfer cancelled. Partial files may remain in " + directory + ".") }
            throw DropFailure("Remote copy failed. Check SSH and remote rsync. Partial files may remain in " + directory + ".")
        }
        return paths.map { directory + "/" + ($0 as NSString).lastPathComponent }
    }
}
