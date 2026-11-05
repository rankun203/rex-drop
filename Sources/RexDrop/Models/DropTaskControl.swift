import Foundation
import Darwin

final class DropTaskControl {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    var isPaused: Bool { condition.lock(); defer { condition.unlock() }; return paused }
    func pause() {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled else { return }
        paused = true
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGSTOP) }
    }
    func resume() {
        condition.lock(); defer { condition.unlock() }
        paused = false
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGCONT) }
        condition.broadcast()
    }
    func cancel() {
        condition.lock()
        cancelled = true; paused = false
        let running = process
        if let running, running.isRunning {
            Darwin.kill(running.processIdentifier, SIGCONT)
            running.terminate()
        }
        condition.broadcast(); condition.unlock()
        if let running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
    func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled { throw DropFailure("Transfer cancelled. Partial copies may remain.") }
    }
    func register(_ process: Process) throws {
        condition.lock(); defer { condition.unlock() }
        self.process = process
        if cancelled {
            if process.isRunning { process.terminate() }
            throw DropFailure("Transfer cancelled. Partial copies may remain.")
        }
        if paused && process.isRunning { Darwin.kill(process.processIdentifier, SIGSTOP) }
    }
    func unregister(_ process: Process) {
        condition.lock(); defer { condition.unlock() }
        if self.process === process { self.process = nil }
    }
}
