import AppKit
import Testing
@testable import RexDrop

@Suite(.serialized)
struct UIStateTests {
    @Test
    func testOnlyDestinationRowsAcceptLiveFileDrops() {
        #expect(nativeFileTypes == [.fileURL])
        #expect(!(acceptsTransfer(.icon, fileCount: 1, preview: false)))
        #expect(!(acceptsTransfer(.background, fileCount: 1, preview: false)))
        #expect(acceptsTransfer(.destination, fileCount: 2, preview: false))
        #expect(!(acceptsTransfer(.destination, fileCount: 0, preview: false)))
        #expect(!(acceptsTransfer(.destination, fileCount: 1, preview: true)))
    }

    @Test
    func testEnteringPopoverInvalidatesPendingIconDismissal() {
        var drag = NativeDragLifecycle()
        drag.enter()
        let iconExit = drag.generation
        #expect(drag.mayDismiss(iconExit))
        drag.enter()
        #expect(!(drag.mayDismiss(iconExit)))
        let rowExit = drag.generation
        #expect(drag.mayDismiss(rowExit))
        drag.end()
        #expect(!(drag.mayDismiss(rowExit)))
    }

    @Test
    func testDestinationOrderingDeduplicatesAndFiltersUnsupportedRows() {
        let sorted = orderedTargets([
            ["id": "local", "kind": "local", "destination_display": "~/site"],
            ["id": "ssh-z", "kind": "ssh", "destination_display": "dev@zulu:/tmp"],
            ["id": "ssh-a", "kind": "ssh", "destination_display": "dev@alpha:/tmp"],
            ["id": "ssh-a", "kind": "ssh", "destination_display": "dev@alpha:/tmp"],
            ["id": "disabled", "kind": "local", "selectable": false]
        ])
        #expect(sorted.compactMap { $0["id"] as? String } == ["ssh-a", "ssh-z", "local"])
        #expect(destinationTitle(["kind": "ssh", "display_name": "dev@host"]) == "dev@host:/tmp")
    }

    @Test
    func testActiveTaskStatesProtectTermination() {
        #expect(TransferState.paused.active)
        #expect(TransferState.cancelling.active)
        #expect(!(TransferState.complete.active))
    }

    @Test
    func testConflictRowsStayCompactAndFailuresExpand() {
        let task = TransferTask(target: ["display_name": "demo"], paths: ["/example/a"])
        #expect(task.preferredHeight == 44)
        #expect(task.collisionPolicy == .ask)
        task.state = .conflict
        #expect(task.preferredHeight == 44)
        #expect(!(task.state.active))
        task.state = .failed
        #expect(task.preferredHeight > 44)
    }

    @Test
    func testRealByteProgressUsesAggregateCounts() {
        let task = TransferTask(target: [:], paths: [])
        #expect(task.progressText == nil)
        task.completedBytes = 12_000_000; task.totalBytes = 40_000_000
        task.fraction = 0.9
        #expect(task.progressFraction == 0.3)
        #expect(task.progressText?.contains("%") == false)
        #expect(task.progressText?.contains("/") == true)
        task.completedBytes = 50_000_000
        #expect(task.progressFraction == 1)
        task.completedBytes = nil; task.totalBytes = nil; task.fraction = .nan
        #expect(task.progressText == nil)
    }

    @Test @MainActor
    func testLongDestinationKeepsIconControlsInsideRow() {
        let owner = AppDelegate()
        let row = TargetRow(target: ["kind": "ssh", "destination_display": String(repeating: "long-destination/", count: 30)], owner: owner, clipboardAvailable: true)
        row.frame = NSRect(x: 0, y: 0, width: 380, height: 65)
        row.layoutSubtreeIfNeeded()
        #expect(row.title.frame.width > 100)
        #expect(row.title.frame.maxX <= row.pasteButton.frame.minX)
        #expect(row.pasteButton.frame.maxX <= row.openButton.frame.minX)
        #expect(row.openButton.frame.maxX <= row.bounds.maxX)
        #expect(row.pasteButton.image != nil)
        #expect(row.pasteButton.title.isEmpty)
        #expect(row.pasteButton.isEnabled)
    }

    @Test @MainActor
    func testProgressBarAndUserResizedWindow() {
        _ = NSApplication.shared
        let owner = AppDelegate()
        owner.makePanel()
        defer { owner.panel.close() }
        let task = TransferTask(target: ["destination_display": "dev@example:/tmp"], paths: ["/example/image.png"])
        task.state = .running; task.completedBytes = 30; task.totalBytes = 100
        owner.tasks = [task]; owner.renderContent()
        let frame = NSRect(x: 50, y: 50, width: 700, height: 230)
        owner.panel.setFrame(frame, display: true)
        owner.updateTask(task)
        owner.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(owner.panel.frame.size == frame.size)
        #expect(owner.panel.styleMask.contains(.resizable))
        let card = owner.cards[task.id]!
        #expect(!card.bar.isHidden && !card.bar.isIndeterminate)
        #expect(card.bar.doubleValue == 0.3)
        #expect(!card.progressLabel.stringValue.contains("%"))
        #expect(abs(card.frame.width - owner.scroll.contentView.bounds.width) < 1)
    }

    @Test @MainActor
    func testUnsupportedClipboardClickStaysOnPasteButton() {
        let owner = AppDelegate()
        let row = TargetRow(target: ["kind": "ssh", "destination_display": "dev@example:/tmp"], owner: owner, clipboardAvailable: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 65))
        host.addSubview(row); row.frame = host.bounds; row.layoutSubtreeIfNeeded()
        #expect(row.pasteButton.isEnabled)
        let point = NSPoint(x: row.pasteButton.frame.midX, y: row.pasteButton.frame.midY)
        #expect(row.hitTest(point) === row.pasteButton)
    }

}
