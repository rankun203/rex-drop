import AppKit

enum ClipboardOutput {
    @discardableResult
    static func copyUploadedPaths(_ paths: [String], kind: String?, board: NSPasteboard = .general) -> Bool {
        guard kind == "ssh", !paths.isEmpty else { return false }
        // Shell quoting preserves spaces and apostrophes without appending Enter.
        let text = paths.map(DropService.shellQuote).joined(separator: " ")
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
