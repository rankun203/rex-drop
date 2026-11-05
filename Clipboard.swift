import AppKit
import Darwin

struct ClipboardFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Retain with a task so generated images remain available through retries.
final class ClipboardPayload {
    let paths: [String]
    let temporaryDirectory: URL?
    private let identity: (dev_t, ino_t)?
    private let lock = NSLock()
    private var cleaned = false

    fileprivate init(paths: [String], temporaryDirectory: URL? = nil) {
        self.paths = paths; self.temporaryDirectory = temporaryDirectory
        var info = stat()
        if let directory = temporaryDirectory, lstat(directory.path, &info) == 0 {
            identity = (info.st_dev, info.st_ino)
        } else { identity = nil }
    }

    func cleanup() {
        lock.lock()
        guard !cleaned else { lock.unlock(); return }
        cleaned = true; lock.unlock()
        guard let directory = temporaryDirectory, let identity else { return }
        var current = stat()
        // Remove only the generated directory we own, preserving a replacement
        // at the same path if another process has changed it since capture.
        guard lstat(directory.path, &current) == 0, current.st_dev == identity.0,
              current.st_ino == identity.1, current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFDIR else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { cleanup() }
}

enum ClipboardInput {
    private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static func canPaste(board: NSPasteboard = .general) -> Bool {
        // Advertising availability reads types only. File/image bytes are
        // requested after the user explicitly chooses a destination's Paste.
        let types = Set(board.types ?? [])
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) || types.contains(jpeg)
    }

    static func capture(board: NSPasteboard = .general) throws -> ClipboardPayload {
        let types = Set(board.types ?? [])
        if types.contains(.fileURL) {
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty, urls.allSatisfy({ url in
                url.isFileURL && url.path.hasPrefix("/") && !url.path.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
            }) else { throw ClipboardFailure("The clipboard does not contain readable local file URLs.") }
            return ClipboardPayload(paths: urls.map { $0.standardizedFileURL.path })
        }
        let png: Data
        if types.contains(.png), let data = board.data(forType: .png), validPNG(data) {
            png = data
        } else {
            let converted = [NSPasteboard.PasteboardType.tiff, jpeg].lazy.compactMap { type -> Data? in
                guard types.contains(type), let source = board.data(forType: type),
                      let image = NSImage(data: source), image.isValid,
                      let representation = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: representation),
                      let data = bitmap.representation(using: .png, properties: [:]), validPNG(data) else { return nil }
                return data
            }.first
            if let converted { png = converted }
            else if types.contains(.png) || types.contains(.tiff) || types.contains(jpeg) {
                throw ClipboardFailure("The clipboard image could not be decoded. Copy the image again.")
            } else { throw ClipboardFailure("Copy files, folders, or an image before choosing Paste.") }
        }
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("rex-drop-clipboard.XXXXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else { throw ClipboardFailure("Could not create a private clipboard image directory.") }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        do {
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = directory.appendingPathComponent("Clipboard-" + timestamp + ".png")
            try png.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return ClipboardPayload(paths: [file.path], temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ClipboardFailure("Could not save the clipboard image. Check available disk space.")
        }
    }

    private static func validPNG(_ data: Data) -> Bool {
        data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) &&
            NSBitmapImageRep(data: data).map { $0.pixelsWide > 0 && $0.pixelsHigh > 0 && $0.cgImage != nil } == true
    }
}
