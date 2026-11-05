import AppKit
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message) }
}
private func isolated(_ test: (NSPasteboard) throws -> Void) throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    try test(board)
}
private func image(_ format: NSBitmapImageRep.FileType) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                       bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let bytes = bitmap.bitmapData else { throw CheckFailure("Image fixture unavailable") }
    memset(bytes, 160, bitmap.bytesPerRow * bitmap.pixelsHigh)
    guard let data = bitmap.representation(using: format, properties: [:]) else { throw CheckFailure("Image encoding failed") }
    return data
}
private func put(_ board: NSPasteboard, _ type: NSPasteboard.PasteboardType, _ data: Data) throws {
    board.clearContents()
    try check(board.setData(data, forType: type), "Could not write isolated pasteboard")
}

@main
struct ClipboardTests {
    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("file URLs and folders take precedence over raw images", filesBeforeImages),
            ("PNG data remains exact in a private generated image", pngCapture),
            ("TIFF and JPEG clipboard images convert to PNG", imageConversions),
            ("invalid PNG falls back to valid TIFF", pngFallback),
            ("text, URLs and file promises are unavailable", unsupported),
            ("invalid images produce a useful capture error", invalidImage),
            ("payload cleanup preserves copied originals and removes generated images", cleanup),
            ("availability checks inspect metadata without materializing data", metadataOnly),
        ]
        var failures = 0
        for (name, body) in cases {
            do { try body(); print("PASS " + name) }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(cases.count - failures)/\(cases.count) clipboard tests passed")
        exit(failures == 0 ? 0 : 1)
    }

    static func filesBeforeImages() throws {
        try isolated { board in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rex-drop-clipboard-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("a file's name.txt"), folder = root.appendingPathComponent("folder")
            try Data("original".utf8).write(to: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            board.clearContents()
            try check(board.writeObjects([file as NSURL, folder as NSURL]), "Could not copy file URL fixtures")
            try check(board.setData(try image(.png), forType: .png), "Could not add image fixture")
            try check(ClipboardInput.canPaste(board: board), "File clipboard unavailable")
            let payload = try ClipboardInput.capture(board: board)
            try check(payload.paths == [file.path, folder.path], "Capture preferred image or changed source names")
            try check(payload.temporaryDirectory == nil, "Files should retain original URLs")
            payload.cleanup()
            try check(FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: folder.path), "Cleanup removed original files")
        }
    }

    static func pngCapture() throws {
        try isolated { board in
            let data = try image(.png)
            try put(board, .png, data)
            let payload = try ClipboardInput.capture(board: board)
            defer { payload.cleanup() }
            guard let directory = payload.temporaryDirectory, let path = payload.paths.first else { throw CheckFailure("Generated image missing") }
            try check(try Data(contentsOf: URL(fileURLWithPath: path)) == data, "Valid PNG was altered")
            try check(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("Clipboard-") && path.hasSuffix(".png"), "Generated image lacks timestamped name")
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o700, "Generated directory is not private")
            let filePermissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            try check(filePermissions?.intValue == 0o600, "Generated image permissions are not private")
        }
    }

    static func imageConversions() throws {
        for (type, format) in [(NSPasteboard.PasteboardType.tiff, NSBitmapImageRep.FileType.tiff), (NSPasteboard.PasteboardType("public.jpeg"), .jpeg)] {
            try isolated { board in
                try put(board, type, image(format))
                try check(ClipboardInput.canPaste(board: board), "Convertible image unavailable")
                let payload = try ClipboardInput.capture(board: board)
                defer { payload.cleanup() }
                let data = try Data(contentsOf: URL(fileURLWithPath: payload.paths[0]))
                try check(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "Converted image is not PNG")
                try check(NSBitmapImageRep(data: data)?.pixelsWide == 2, "Converted PNG did not decode")
            }
        }
    }

    static func pngFallback() throws {
        try isolated { board in
            try put(board, .png, Data("invalid".utf8))
            try check(board.setData(try image(.tiff), forType: .tiff), "Could not add TIFF fallback")
            let payload = try ClipboardInput.capture(board: board)
            defer { payload.cleanup() }
            let data = try Data(contentsOf: URL(fileURLWithPath: payload.paths[0]))
            try check(NSBitmapImageRep(data: data)?.pixelsHigh == 2, "Invalid PNG blocked valid TIFF fallback")
        }
    }

    static func unsupported() throws {
        for type in [NSPasteboard.PasteboardType.string, .URL, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")] {
            try isolated { board in
                try put(board, type, Data("https://example.test/".utf8))
                try check(!ClipboardInput.canPaste(board: board), "Unsupported pasteboard advertised availability")
                do { _ = try ClipboardInput.capture(board: board); throw CheckFailure("Unsupported clipboard captured") }
                catch is ClipboardFailure { }
            }
        }
        try isolated { board in
            try put(board, .fileURL, Data("https://example.test/image.png".utf8))
            do { _ = try ClipboardInput.capture(board: board); throw CheckFailure("Non-file URL captured") }
            catch is ClipboardFailure { }
        }
    }

    static func invalidImage() throws {
        try isolated { board in
            try put(board, .png, Data([137, 80, 78, 71, 13, 10, 26, 10, 0]))
            do { _ = try ClipboardInput.capture(board: board); throw CheckFailure("Invalid image captured") }
            catch let error as ClipboardFailure { try check(error.localizedDescription.contains("decoded"), "Image failure lacks recovery advice") }
        }
    }

    static func cleanup() throws {
        try isolated { board in
            try put(board, .png, image(.png))
            var payload: ClipboardPayload? = try ClipboardInput.capture(board: board)
            let directory = payload!.temporaryDirectory!
            payload = nil
            try check(!FileManager.default.fileExists(atPath: directory.path), "Deinitialization leaked generated image")
            let explicit = try ClipboardInput.capture(board: board)
            let otherDirectory = explicit.temporaryDirectory!
            explicit.cleanup(); explicit.cleanup()
            try check(!FileManager.default.fileExists(atPath: otherDirectory.path), "Idempotent cleanup leaked generated image")
        }
    }

    static func metadataOnly() throws {
        final class Provider: NSObject, NSPasteboardItemDataProvider {
            var requests = 0
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
                requests += 1; item.setData(Data("invalid".utf8), forType: type)
            }
        }
        try isolated { board in
            let provider = Provider(), item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.png])
            board.clearContents()
            try check(board.writeObjects([item]), "Could not write lazy image fixture")
            try check(ClipboardInput.canPaste(board: board), "Lazy image type unavailable")
            try check(provider.requests == 0, "Availability check materialized clipboard data")
        }
    }
}
