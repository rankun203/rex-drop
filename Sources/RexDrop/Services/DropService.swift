import Foundation

enum DropBackend {
    static func targets() throws -> [[String: Any]] { try DropService().targets() }
    static func transfer(_ request: [String: Any]) throws -> [String: Any] { try DropService().transfer(request) }
    static func openRemoteDestination(_ metadata: [String: Any]) throws { try DropService().openRemoteDestination(metadata) }
}

final class DropService {
    typealias Runner = ([String], TimeInterval, [String: String]?) throws -> Data
    let runner: Runner?
    let rexPath: String?
    let control: DropTaskControl
    let progress: (DropProgress) -> Void
    let startReader: (Int32) throws -> String
    let argvReader: (Int32) throws -> [String]
    init(runner: Runner? = nil, rexPath: String? = nil,
         processStart: ((Int32) throws -> String)? = nil,
         processArgv: ((Int32) throws -> [String])? = nil,
         control: DropTaskControl = DropTaskControl(), progress: @escaping (DropProgress) -> Void = { _ in }) {
        self.runner = runner; self.rexPath = rexPath
        self.control = control
        let eventLock = NSLock()
        var lastEvent = Date.distantPast, lastPhase = "", lastFile = ""
        self.progress = { event in
            eventLock.lock()
            let now = Date()
            let emit = event.phase != lastPhase || event.currentFile != lastFile ||
                now.timeIntervalSince(lastEvent) >= 0.1 ||
                (event.totalFiles > 0 && event.completedFiles == event.totalFiles)
            if emit { lastEvent = now; lastPhase = event.phase; lastFile = event.currentFile }
            eventLock.unlock()
            if emit { progress(event) }
        }
        self.startReader = processStart ?? DropService.processStart
        self.argvReader = processArgv ?? DropService.processArgv
    }
}
