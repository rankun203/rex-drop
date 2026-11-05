import Foundation

extension DropService {
    func rexBinary() throws -> String {
        if let rexPath { return rexPath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
                          "/Applications/Rex.app/Contents/MacOS/rex"]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(String(directory) + "/rex")
        }
        guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DropFailure("Rex CLI unavailable. Open the local Rex app first.")
        }
        return result
    }

    func api(_ method: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        let output = try execute([rexBinary(), "--autostart=false", "api", "call", method,
                                 String(decoding: data, as: UTF8.self)], 15, Self.localEnvironment())
        guard let value = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw DropFailure("Rex returned an invalid API response.")
        }
        return value
    }
}
