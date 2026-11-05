import AppKit

let nativeFileTypes: [NSPasteboard.PasteboardType] = [.fileURL]

func containsFiles(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
}
