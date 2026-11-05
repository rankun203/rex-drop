import Foundation
import Darwin

extension DropService {
    static func localEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("REX") }
    }

    static func run(_ command: [String], _ timeout: TimeInterval = 15,
                    _ environment: [String: String]? = nil) throws -> Data {
        try runControlled(command, timeout, environment)
    }

    func execute(_ command: [String], _ timeout: TimeInterval = 15, _ environment: [String: String]? = nil,
                 output: ((Data) -> Void)? = nil) throws -> Data {
        try control.checkpoint()
        let result: Data
        if let runner { result = try runner(command, timeout, environment) }
        else { result = try Self.runControlled(command, timeout, environment, control: control, output: output) }
        try control.checkpoint()
        return result
    }

    static func runControlled(_ command: [String], _ timeout: TimeInterval,
                              _ environment: [String: String]?, control: DropTaskControl? = nil,
                              output observer: ((Data) -> Void)? = nil) throws -> Data {
        try control?.checkpoint()
        guard let executable = command.first else { throw DropFailure("Required command is missing.") }
        let process = Process(), output = Pipe(), errors = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw DropFailure("Required command could not start.") }
        do { try control?.register(process) } catch {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        defer { control?.unregister(process) }
        // Poll both pipes without blocking. Proxy subprocesses can retain pipe
        // descriptors after SSH exits, so EOF also has a bounded grace period.
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        defer { for handle in handles { try? handle.close() } }
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0) }
        for descriptor in descriptors { _ = fcntl(descriptor.fd, F_SETFL, fcntl(descriptor.fd, F_GETFL) | O_NONBLOCK) }
        var data = Data(), tooLarge = false, eof = [false, false], endedAt: Date?
        var activeElapsed: TimeInterval = 0
        var lastTick = Date()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if control?.isCancelled == true {
                process.terminate()
                if done.wait(timeout: .now() + 1) == .timedOut { Darwin.kill(process.processIdentifier, SIGKILL) }
                throw DropFailure("Transfer cancelled. Partial copies may remain.")
            }
            let now = Date()
            if control?.isPaused != true { activeElapsed += now.timeIntervalSince(lastTick) }
            lastTick = now
            if endedAt == nil && done.wait(timeout: .now()) == .success { endedAt = Date() }
            if endedAt != nil && eof.allSatisfy({ $0 }) { break }
            if let endedAt, Date().timeIntervalSince(endedAt) > 2 {
                throw DropFailure("Command output did not finish. Check the selected connection.")
            }
            if endedAt == nil && activeElapsed >= timeout {
                process.terminate()
                if done.wait(timeout: .now() + 1) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 1)
                }
                throw DropFailure("Operation timed out. Check the selected pane and connection.")
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            for index in descriptors.indices where !eof[index] {
                // Bound each drain batch so continuous output still reaches
                // timeout checks and the other descriptor promptly.
                for _ in 0..<16 {
                    let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                    if count == 0 { eof[index] = true; descriptors[index].fd = -1; break }
                    if count < 0 { break }
                    if index == 0 {
                        observer?(Data(buffer.prefix(count)))
                        if data.count + count <= 8 * 1024 * 1024 { data.append(contentsOf: buffer.prefix(count)) }
                        else if observer == nil { tooLarge = true }
                    }
                }
            }
        }
        guard process.terminationStatus == 0 else {
            // SSH stderr may contain private arguments and paths.
            throw DropFailure("Command failed. Check Rex, SSH authentication, and remote rsync availability.")
        }
        guard !tooLarge else { throw DropFailure("Command returned too much output.") }
        return data
    }
}
