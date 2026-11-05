import AppKit

extension AppDelegate {
    func start(_ task: TransferTask, retry: Bool) {
        if retry { task.collisionPolicy = .ask }
        task.conflicts = []
        task.attempt += 1; let attempt = task.attempt
        task.control = DropTaskControl(); task.started = false; task.state = .queued; task.error = ""; task.fraction = nil
        task.currentFile = ""; task.completedFiles = 0; task.totalFiles = 0
        task.openDestination = nil; task.copiedPaths = []
        updateTask(task)
        let control = task.control, original = task.target, paths = task.paths, policy = task.collisionPolicy
        let operation = BlockOperation { [weak self, weak task] in
            guard let task else { return }
            do {
                var target = original
                if retry {
                    let latest = try DropBackend.targets()
                    guard let key = original["destination_key"] as? String,
                          let current = latest.first(where: { ($0["destination_key"] as? String) == key && ($0["selectable"] as? Bool) != false && ($0["kind"] as? String) != "unsupported" }) else {
                        throw DropFailure("Destination unavailable. Refresh destinations and drop again.")
                    }
                    target = current
                }
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.started = true
                    task.target = target
                    if task.state == .queued { task.state = .running }
                    self?.updateTask(task)
                }
                let service = DropService(control: control, progress: { progress in
                    DispatchQueue.main.async {
                        guard task.attempt == attempt, task.state.active else { return }
                        task.phase = progress.phase; task.currentFile = progress.currentFile
                        task.completedFiles = progress.completedFiles; task.totalFiles = progress.totalFiles; task.fraction = progress.fraction
                        self?.updateTask(task)
                    }
                })
                let response = try service.transfer(["target": target, "paths": paths, "collision_policy": policy.rawValue])
                guard response["ok"] as? Bool == true else { throw DropFailure(response["error"] as? String ?? "Transfer failed.") }
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.openDestination = response["open_destination"] as? [String: Any]
                    task.copiedPaths = response["paths"] as? [String] ?? []
                    task.state = .complete; self?.updateTask(task)
                }
            } catch let conflict as LocalConflict {
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.state = control.isCancelled ? .cancelled : .conflict
                    task.conflicts = conflict.paths
                    task.error = conflict.recoveryDirectory.map { "Recovery copies: " + $0 } ?? ""
                    self?.updateTask(task)
                }
            } catch {
                DispatchQueue.main.async {
                    guard task.attempt == attempt else { return }
                    task.state = control.isCancelled ? .cancelled : .failed
                    task.error = error.localizedDescription; self?.updateTask(task)
                    self?.refresh()
                }
            }
        }
        task.operation = operation
        queue.addOperation(operation)
    }
    func updateQuitButton() {
        quitButton.isEnabled = !transferring && !preview
        quitButton.toolTip = transferring ? "Finish or cancel transfers before quitting" : nil
    }
    func updateTask(_ task: TransferTask) { cards[task.id]?.update(); resizeProgressPanel(); updateQuitButton() }
    func openDestination(_ task: TransferTask) {
        guard !preview, task.state == .complete, !task.opening else { return }
        if task.target["kind"] as? String == "local" {
            guard !task.copiedPaths.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(task.copiedPaths.map { URL(fileURLWithPath: $0) })
            return
        }
        guard let destination = task.openDestination else { return }
        task.opening = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try DropService().openRemoteDestination(destination)
                DispatchQueue.main.async {
                    task.opening = false; task.error = ""; self?.updateTask(task)
                    let rex = NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == "com.superlogical.rex"
                    }
                    rex?.activate(options: [])
                }
            } catch {
                DispatchQueue.main.async {
                    task.opening = false; task.error = error.localizedDescription; self?.updateTask(task)
                    let alert = NSAlert(); alert.messageText = "Couldn’t open destination"
                    alert.informativeText = error.localizedDescription
                    if let panel = self?.panel { alert.beginSheetModal(for: panel) }
                }
            }
        }
    }
    func resolveConflict(_ task: TransferTask, policy: CollisionPolicy) {
        guard !preview, task.state == .conflict, policy != .ask else { return }
        task.collisionPolicy = policy
        start(task, retry: false)
    }
    func primaryAction(_ task: TransferTask) {

        switch task.state {
        case .queued, .running: task.control.pause(); task.state = .paused
        case .paused: task.control.resume(); task.state = task.started ? .running : .queued
        case .failed, .cancelled: start(task, retry: true)
        default: break
        }
        updateTask(task)
    }
    func secondaryAction(_ task: TransferTask) {
        if task.state == .conflict { task.state = .cancelled; updateTask(task); return }
        if task.state.active {
            task.control.cancel()
            if task.started { task.state = .cancelling }
            else { task.operation?.cancel(); task.state = .cancelled }
            updateTask(task)
        } else {
            tasks.removeAll { $0.id == task.id }; cards.removeValue(forKey: task.id)
            if tasks.isEmpty { panel.orderOut(nil) }
            else { renderContent() }
        }
    }

}
