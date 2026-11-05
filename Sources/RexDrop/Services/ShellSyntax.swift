import Foundation

extension DropService {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }


    // Small POSIX word splitter for inspecting remote commands, never executing
    // them. Unbalanced quotes and explicit second SSH hops disable targeting.
    static func shellWords(_ value: String) -> [String]? {
        var result: [String] = [], word = "", quote: Character?, escape = false, active = false
        for char in value {
            if escape { word.append(char); escape = false; active = true; continue }
            if char == "\\" && quote != "'" { escape = true; active = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { word.append(char) }
                active = true
            } else if char == "'" || char == "\"" { quote = char; active = true }
            else if char.isWhitespace {
                if active { result.append(word); word = ""; active = false }
            } else { word.append(char); active = true }
        }
        guard quote == nil && !escape else { return nil }
        if active { result.append(word) }
        return result
    }
}
