import AppKit
import Foundation
import Darwin

@MainActor
enum CloseChecks {
    static func run(_ app: AppDelegate) async throws {
        guard let path = argumentValue("--capture-dir"), let state = argumentValue("--state-dir") else { throw LaunchError.message("Isolated test state and capture folder required") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for _ in 0..<120 {
            if app.store.inventory != nil && app.store.resources.system?.cpu != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try FeatureChecks.require(app.store.inventory != nil && app.store.resources.system?.cpu != nil, "Initial scan/monitor sample missing")
        let originalPID = getpid()
        func iconPixels(_ image: NSImage) throws -> NSBitmapImageRep {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw LaunchError.message("Icon rendering failed") }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState(); return bitmap
        }
        guard let logo = app.applicationLogo else { throw LaunchError.message("Bundled application logo missing") }
        let expectedLogo = try iconPixels(logo)
        func verifyDockIcon(_ name: String) throws {
            let actual = try iconPixels(NSApplication.shared.applicationIconImage)
            try actual.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
            try expectedLogo.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("dock-logo-reference.png"))
            guard let wanted = expectedLogo.bitmapData, let observed = actual.bitmapData else { throw LaunchError.message("Icon pixels missing") }
            var error = 0.0
            for row in 0..<256 { for byte in 0..<(256 * 4) { error += abs(Double(wanted[row * expectedLogo.bytesPerRow + byte]) - Double(observed[row * actual.bytesPerRow + byte])) } }
            try FeatureChecks.require(error / Double(256 * 256 * 4 * 255) < 0.02, "Dock icon content does not match the bundled logo")
        }
        try verifyDockIcon("dock-logo-startup")
        let serviceIdentities = app.store.services.records.compactMap { spec -> (Int32, UInt64)? in
            guard let pid = spec.pid, let birth = spec.processStart else { return nil }
            return (pid, birth)
        }
        var checks: [String] = []
        var confirmations = 0
        var confirmationChoice = 1
        var captureError: String?
        app.exitAlertPresenter = { alert in
            confirmations += 1
            if alert.buttons.count != 2 || alert.buttons[0].keyEquivalent != "" || alert.buttons[1].keyEquivalent != "\r" { captureError = "Cancel is not the default confirmation action" }
            alert.layout()
            if app.passiveTesting {
                let screen = NSScreen.main?.visibleFrame ?? .zero
                alert.window.setFrameOrigin(NSPoint(x: screen.maxX + 200, y: screen.minY + 100))
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            var modalClosed = false
            let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                MainActor.assumeIsolated {
                    do {
                        guard let view = alert.window.contentView else { throw LaunchError.message("Confirmation view missing") }
                        try app.captureView(view, name: confirmationChoice == 1 ? "exit-confirmation-cancel" : "exit-confirmation-accept", folder: folder)
                    } catch { captureError = error.localizedDescription }
                    if confirmationChoice == 1 && captureError == nil,
                       let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: alert.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                        alert.window.sendEvent(key)
                    } else { alert.buttons[captureError == nil ? confirmationChoice : 1].performClick(nil) }
                }
            }
            let timeout = Timer(timeInterval: 2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if !modalClosed { captureError = "Enter did not cancel the confirmation"; alert.buttons[1].performClick(nil) }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timeout, forMode: .common); RunLoop.main.add(timeout, forMode: .modalPanel)
            let response = alert.runModal(); modalClosed = true; timeout.invalidate()
            return response
        }
        try FeatureChecks.require(app.store.windowCloseBehavior == .keepRunning, "New profile does not default to keeping the program running")
        try app.capture("engines", folder: folder)
        app.window.performClose(nil)
        try FeatureChecks.require(!app.window.isVisible && app.store.hiddenToStatusBar && confirmations == 0 && kill(originalPID, 0) == 0 && app.statusItem.isVisible, "Default close terminated the process or showed a confirmation")
        let sampledAt = app.store.resources.system?.sampledAt
        try await Task.sleep(nanoseconds: 3_500_000_000)
        try FeatureChecks.require(sampledAt != app.store.resources.system?.sampledAt, "Monitoring stopped after hiding the window")
        _ = app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        try FeatureChecks.require(app.window.isVisible && getpid() == originalPID, "Reopening created another process or failed")
        try verifyDockIcon("dock-logo-restored")
        checks.append("Default red close hides only the main window; process, menu-bar icon and monitoring stay alive; reopen keeps same PID")
        checks.append("Dock application icon matches bundled logo on startup and after background/foreground activation changes")

        func allMenuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(allMenuItems) ?? []) }
        }
        let menuItems = allMenuItems(NSApplication.shared.mainMenu!)
        try FeatureChecks.require(!menuItems.contains { $0.title.contains("收起到状态栏") || $0.title.contains("驻留状态栏") }, "Dedicated status-bar command remains")
        try FeatureChecks.require(menuItems.contains { $0.title == "关闭窗口" && $0.keyEquivalent == "w" && $0.action == #selector(NSWindow.performClose(_:)) } && menuItems.contains { $0.title == "设置…" && $0.keyEquivalent == "," }, "Native close/settings shortcuts missing")
        checks.append("Native Close Window and Settings menu shortcuts; dedicated status-bar command removed")

        app.showSettings()
        try await Task.sleep(nanoseconds: 250_000_000); try app.capture("settings-default", folder: folder)
        app.store.windowCloseBehavior = .confirmQuit
        try await Task.sleep(nanoseconds: 250_000_000); try app.capture("settings-confirm-quit", folder: folder)
        let restored = AppStore(stateDirectory: URL(fileURLWithPath: state))
        try FeatureChecks.require(restored.windowCloseBehavior == .confirmQuit && app.store.preferencesError == nil, "Close behavior did not persist")
        app.settingsWindow?.performClose(nil)
        try FeatureChecks.require(app.window.isVisible && confirmations == 0 && kill(originalPID, 0) == 0, "Closing Settings quit the program")
        checks.append("Both settings choices render; quit choice persists across reopening; closing Settings never quits the manager")

        app.window.miniaturize(nil)
        try FeatureChecks.require(!app.window.isVisible && confirmations == 0 && kill(originalPID, 0) == 0, "Minimize invoked the quit preference")
        app.showMainWindow()
        checks.append("Minimizing still hides the main window when close-to-quit is enabled")
        app.window.performClose(nil)
        try FeatureChecks.require(confirmations == 1 && app.window.isVisible && kill(originalPID, 0) == 0 && captureError == nil, captureError ?? "Cancel confirmation did not preserve the visible window and process")
        checks.append("Close-to-quit always asks again; pressing Enter activates Cancel and preserves the window and process")

        for _ in 0..<20 { await app.store.services.refresh() }
        try FeatureChecks.require(serviceIdentities.allSatisfy { processStartTime($0.0) == $0.1 }, "Existing model service identity changed during close/refresh tests")
        checks.append("Twenty explicit service refreshes complete without crash; pre-existing managed model PIDs/births unchanged")
        confirmationChoice = 0
        app.onWillTerminate = {
            do {
                guard captureError == nil, confirmations == 2 else { throw LaunchError.message("Final confirmation did not complete") }
                guard serviceIdentities.allSatisfy({ processStartTime($0.0) == $0.1 }) else { throw LaunchError.message("Model service interrupted by manager quit") }
                checks.append("Accepting the second close confirmation really quits the manager; model processes remain alive")
                let report: [String: Any] = ["result": "passed", "checks": checks, "manager_pid": originalPID, "confirmation_count": confirmations, "default_close": "keepRunning", "quit_preference_persisted": true, "existing_managed_services": serviceIdentities.count, "appearance": argumentValue("--appearance") ?? "light"]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("close-lifecycle.json"))
                print("Close behavior and refresh checks passed: \(folder.path)")
                fflush(stdout)
            } catch { fputs("CLOSE TERMINATION CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        app.window.performClose(nil)
        throw LaunchError.message("Confirmed quit did not terminate the application")
    }
}
