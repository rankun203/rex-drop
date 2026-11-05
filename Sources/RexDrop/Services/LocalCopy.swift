import Foundation
import Darwin

extension DropService {
    static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 32 || ($0.value >= 127 && $0.value <= 159) }
    }

    static func info(_ path: String) -> stat? {
        var value = stat()
        return lstat(path, &value) == 0 ? value : nil
    }

    static func validateSources(_ paths: [String], allowDuplicateBasenames: Bool = false) throws -> [String] {
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
            if !names.insert(name).inserted && !allowDuplicateBasenames { throw DropFailure("Dropped items have duplicate basenames. Transfer them separately.") }
            result.append(path)
        }
        return result
    }

    static func copyLocal(_ paths: [String], directory: String,
                          control: DropTaskControl = DropTaskControl(),
                          progress: @escaping (DropProgress) -> Void = { _ in },
                          collisionPolicy: CollisionPolicy = .ask) throws -> [String] {
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
        var destinations = paths.map { root.appendingPathComponent(($0 as NSString).lastPathComponent).path }
        let conflicts = destinations.filter { info($0) != nil }
        if collisionPolicy == .ask && !conflicts.isEmpty { throw LocalConflict(paths: conflicts) }
        let originalNames = Set(destinations.map { ($0 as NSString).lastPathComponent.lowercased() })
        var plannedNames: Set<String> = []
        func unusedDestination(for source: String) throws -> String {
            let name = (source as NSString).lastPathComponent
            let isDirectory = info(source).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
            let ext = isDirectory ? "" : (name as NSString).pathExtension
            let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            for number in 2...100_000 {
                let candidate = stem + " \(number)" + (ext.isEmpty ? "" : "." + ext)
                let path = root.appendingPathComponent(candidate).path
                if !originalNames.contains(candidate.lowercased()) && !plannedNames.contains(candidate.lowercased()) && info(path) == nil {
                    plannedNames.insert(candidate.lowercased()); return path
                }
            }
            throw DropFailure("Could not choose an unused filename.")
        }
        if collisionPolicy == .keepBoth {
            for index in paths.indices {
                let name = (destinations[index] as NSString).lastPathComponent.lowercased()
                if info(destinations[index]) != nil || plannedNames.contains(name) { destinations[index] = try unusedDestination(for: paths[index]) }
                else { plannedNames.insert(name) }
            }
        }
        let sourceIdentities = paths.compactMap { info($0) }
        let realSources = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        func unsafeReplacement(_ destination: String, _ existing: stat) -> Bool {
            let realDestination = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            return sourceIdentities.contains { $0.st_dev == existing.st_dev && $0.st_ino == existing.st_ino } ||
                realSources.contains { source in
                    source == realDestination || (existing.st_mode & S_IFMT == S_IFDIR && source.hasPrefix(realDestination + "/"))
                }
        }
        if collisionPolicy == .replace {
            for destination in destinations {
                guard let existing = info(destination) else { continue }
                if unsafeReplacement(destination, existing) {
                    throw DropFailure("A dropped item cannot replace itself or a folder containing another dropped item. Choose Keep Both.")
                }
            }
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
        var preserveStage = false
        defer { if !preserveStage { try? manager.removeItem(at: stage) } }
        let stagedPaths = paths.indices.map { stage.appendingPathComponent("item-\($0)").path }
        do {
            for index in paths.indices { try copy(paths[index], stagedPaths[index]) }
        } catch {
            if control.isCancelled { throw DropFailure("Transfer cancelled. Partial copies may remain.") }
            throw (error as? DropFailure) ?? DropFailure("Could not read or stage a dropped item. Check file permissions and available space.")
        }
        var backups: [Int: String] = [:], published: [Int: stat] = [:]
        do {
            for index in paths.indices {
                try control.checkpoint()
                progress(DropProgress(phase: "Publishing", currentFile: (destinations[index] as NSString).lastPathComponent,
                                      completedFiles: completedFiles, totalFiles: totalFiles, fraction: 1))
                try control.checkpoint()
                if collisionPolicy == .replace && info(destinations[index]) != nil {
                    if let existing = info(destinations[index]), unsafeReplacement(destinations[index], existing) {
                        throw DropFailure("A replacement became a dropped source. Choose Keep Both.")
                    }
                    let backup = stage.appendingPathComponent("original-\(index)").path
                    // Keep originals on the same volume until the entire batch
                    // publishes. Move the entry itself, including symlinks.
                    guard renamex_np(destinations[index], backup, UInt32(RENAME_EXCL)) == 0 else {
                        throw DropFailure("A destination changed before replacement. Try again.")
                    }
                    backups[index] = backup
                    if let existing = info(backup), sourceIdentities.contains(where: { $0.st_dev == existing.st_dev && $0.st_ino == existing.st_ino }) {
                        throw DropFailure("A replacement became a dropped source. Choose Keep Both.")
                    }
                    progress(DropProgress(phase: "Replacing", currentFile: (destinations[index] as NSString).lastPathComponent,
                                          completedFiles: completedFiles, totalFiles: totalFiles, fraction: 1))
                    try control.checkpoint()
                }
                guard let identity = info(stagedPaths[index]) else { throw DropFailure("A staged item became unavailable.") }
                while renamex_np(stagedPaths[index], destinations[index], UInt32(RENAME_EXCL)) != 0 {
                    let failure = errno
                    if failure == EEXIST && collisionPolicy == .keepBoth {
                        destinations[index] = try unusedDestination(for: paths[index])
                        try control.checkpoint()
                        continue
                    }
                    if failure == EEXIST && collisionPolicy == .ask { throw LocalConflict(paths: [destinations[index]]) }
                    throw DropFailure("A destination changed during publication. Try again.")
                }
                published[index] = identity
            }
            // This checkpoint is the commit boundary. Cancellation before it
            // restores originals; afterward the accepted replacements are done.
            try control.checkpoint()
        } catch {
            var recovered = true
            // Published items can gain edits without changing their inode (for
            // example, files added inside a folder). Retain any rolled-back
            // publications rather than deleting a concurrent writer's work.
            if !published.isEmpty { preserveStage = true }
            for index in paths.indices.reversed() {
                if let identity = published[index] {
                    // Another writer may replace our published item while a
                    // later item fails. Preserve their entry and our backup.
                    if let current = info(destinations[index]), current.st_dev == identity.st_dev && current.st_ino == identity.st_ino {
                        if renamex_np(destinations[index], stagedPaths[index], UInt32(RENAME_EXCL)) != 0 { recovered = false }
                    } else if info(destinations[index]) != nil { recovered = false }
                }
                if let backup = backups[index], renamex_np(backup, destinations[index], UInt32(RENAME_EXCL)) != 0 { recovered = false }
            }
            if !recovered {
                preserveStage = true
                throw DropFailure("A destination changed during rollback. Original items are preserved for recovery in \(stage.path).")
            }
            if preserveStage {
                if let conflict = error as? LocalConflict { throw LocalConflict(paths: conflict.paths, recoveryDirectory: stage.path) }
                throw DropFailure(error.localizedDescription + " Originals restored; copies retained for recovery in \(stage.path).")
            }
            throw error
        }
        return destinations
    }
}
