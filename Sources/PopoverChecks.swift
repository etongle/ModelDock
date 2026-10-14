import AppKit
import Foundation

@MainActor
enum PopoverChecks {
    static func run(_ app: AppDelegate) async throws {
        guard argumentValue("--state-dir") != nil, app.store.services.records.isEmpty else { throw LaunchError.message("Popover checks require isolated state") }
        let folder = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-popover-checks")
        try ConnectionFiles.privateDirectory(folder)
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        app.window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 350_000_000)
        defer { _ = previousApp?.activate(options: []) }
        app.toggleStatusPopover(); try await Task.sleep(nanoseconds: 350_000_000)
        try ConnectionChecks.require(app.statusPopover.isShown, "Menu-bar panel failed to open")
        guard let popoverWindow = app.statusPopover.contentViewController?.view.window else { throw LaunchError.message("Popover window missing") }
        func click(window: NSWindow, point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApplication.shared.postEvent(event, atStart: false) }
            }
        }
        // Header label has no action; the panel must remain open for an inside click.
        click(window: popoverWindow, point: NSPoint(x: 100, y: popoverWindow.contentView!.bounds.height - 30))
        try await Task.sleep(nanoseconds: 250_000_000)
        try ConnectionChecks.require(app.statusPopover.isShown, "Inside click dismissed the panel")
        // Click the manager's noninteractive header in this same process.
        click(window: app.window, point: NSPoint(x: 25, y: app.window.contentView!.bounds.height - 95))
        try await Task.sleep(nanoseconds: 300_000_000)
        try ConnectionChecks.require(!app.statusPopover.isShown, "Outside click did not dismiss the menu-bar panel (events: \(app.outsideClicks.observedEventCount), last point: \(app.outsideClicks.lastPoint), main frame: \(app.window.frame), panel: \(popoverWindow.frame), button: \(app.outsideClicks.lastButtonRect))")
        app.toggleStatusPopover(); try await Task.sleep(nanoseconds: 200_000_000)
        try ConnectionChecks.require(app.statusPopover.isShown, "Panel failed to reopen after dismissal")
        app.toggleStatusPopover(); try ConnectionChecks.require(!app.statusPopover.isShown, "Status icon failed to toggle closed")
        let popover = NSRect(x: 20, y: 50, width: 390, height: 600), button = NSRect(x: 20, y: 700, width: 150, height: 24)
        try ConnectionChecks.require(PopoverOutsideClickMonitor.isOutside(NSPoint(x: 600, y: 100), popover: popover, button: button) && !PopoverOutsideClickMonitor.isOutside(NSPoint(x: 40, y: 710), popover: popover, button: button), "Global click classification or status-icon protection wrong")
        try ConnectionChecks.require(PopoverOutsideClickMonitor.shouldClose(NSPoint(x: 40, y: 710), content: popover, button: button, global: true) && !PopoverOutsideClickMonitor.shouldClose(NSPoint(x: 40, y: 710), content: popover, button: button, global: false) && PopoverOutsideClickMonitor.shouldClose(NSPoint(x: 60, y: 655), content: popover, button: button, global: false), "Hidden status item or popover arrow click did not dismiss")
        try ConnectionFiles.json(["result": "passed", "checks": ["actual AppKit inside/outside mouse events", "inside controls retain panel", "outside same-app click dismisses", "status icon toggles and reopens", "desktop/outside geometry and icon protection", "arrow and hidden status item clicks dismiss"], "globalDesktopClickInjected": false]).write(to: folder.appendingPathComponent("result.json"))
        print("Popover checks passed"); NSApplication.shared.terminate(nil)
    }
}
