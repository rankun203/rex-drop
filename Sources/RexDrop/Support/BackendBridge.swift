import AppKit

struct Backend {
    static func run(_ command: String, payload: [String: Any]? = nil,
                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: [String: Any]
                if command == "targets" { result = ["targets": try DropBackend.targets()] }
                else { result = try DropBackend.transfer(payload ?? [:]) }
                DispatchQueue.main.async { completion(.success(result)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}
