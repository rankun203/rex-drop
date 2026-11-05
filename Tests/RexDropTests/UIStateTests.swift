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
}
