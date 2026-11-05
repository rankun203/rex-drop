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
        #expect(task.percentage == 30)
        #expect(task.progressText?.contains("30%") == true)
        #expect(task.progressText?.contains("/") == true)
        task.completedBytes = 50_000_000
        #expect(task.percentage == 100)
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
        #expect(row.pasteButton.frame.maxX <= row.openIcon.frame.minX)
        #expect(row.openIcon.frame.maxX <= row.bounds.maxX)
        #expect(row.pasteButton.image != nil)
        #expect(row.pasteButton.title.isEmpty)
        #expect(row.pasteButton.isEnabled)
    }

}
