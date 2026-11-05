import AppKit

/// Observe clicks only while the popover is visible. Drag reception remains
/// entirely in the native drop views; no global pointer polling is involved.
final class PopoverClickDismissal {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start(popover: NSPopover, statusWindow: NSWindow?, dismiss: @escaping () -> Void) {
        stop()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak popover, weak statusWindow] event in
            if event.window !== popover?.contentViewController?.view.window && event.window !== statusWindow {
                dismiss()
            }
            return event
        }
        // Mouse-click observation requires no keyboard/accessibility access.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in dismiss() }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
    }

    deinit { stop() }
}
