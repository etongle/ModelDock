import AppKit

@MainActor
final class PopoverOutsideClickMonitor {
    private var local: Any?
    private var global: Any?
    private weak var popover: NSPopover?
    private weak var button: NSStatusBarButton?
    private(set) var observedEventCount = 0
    private(set) var lastPoint: NSPoint = .zero
    private(set) var lastButtonRect: NSRect = .zero
    static func isOutside(_ point: NSPoint, popover: NSRect, button: NSRect) -> Bool { !popover.contains(point) && !button.contains(point) }
    func start(popover: NSPopover, button: NSStatusBarButton) {
        stop(); self.popover = popover; self.button = button
        observedEventCount = 0
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event // Preserve the original click, including controls in other windows.
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }
    private func handle(_ event: NSEvent) {
        guard let popover, popover.isShown, let window = popover.contentViewController?.view.window else { return }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        observedEventCount += 1; lastPoint = point
        let buttonRect = button.flatMap { button in button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } } ?? .zero
        lastButtonRect = buttonRect
        if Self.isOutside(point, popover: window.frame, button: buttonRect) { popover.close() }
    }
    func stop() {
        if let local { NSEvent.removeMonitor(local) }; if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil; popover = nil; button = nil
    }
}
