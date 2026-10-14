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
    /// `content` excludes the popover arrow, so clicking the arrow dismisses the panel. A global event was
    /// delivered to another app and can never reach the status button (e.g. an item hidden under the notch),
    /// so the button rect only protects local clicks that the button itself toggles.
    static func shouldClose(_ point: NSPoint, content: NSRect, button: NSRect, global: Bool) -> Bool {
        global ? !content.contains(point) : isOutside(point, popover: content, button: button)
    }
    func start(popover: NSPopover, button: NSStatusBarButton) {
        stop(); self.popover = popover; self.button = button
        observedEventCount = 0
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, global: false) }
            return event // Preserve the original click, including controls in other windows.
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, global: true) }
        }
    }
    private func handle(_ event: NSEvent, global: Bool) {
        guard let popover, popover.isShown, let view = popover.contentViewController?.view, let window = view.window else { return }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        observedEventCount += 1; lastPoint = point
        let buttonRect = button.flatMap { button in button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } } ?? .zero
        lastButtonRect = buttonRect
        let content = window.convertToScreen(view.convert(view.bounds, to: nil))
        if Self.shouldClose(point, content: content, button: buttonRect, global: global) { popover.close() }
    }
    func stop() {
        if let local { NSEvent.removeMonitor(local) }; if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil; popover = nil; button = nil
    }
}
