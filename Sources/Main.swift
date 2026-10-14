import AppKit
import SwiftUI
import Foundation

func argumentValue(_ key: String) -> String? {
    let values = CommandLine.arguments
    guard let index = values.firstIndex(of: key), values.count > index + 1 else { return nil }
    return values[index + 1]
}

@MainActor
final class ManagerWindow: NSWindow {
    var minimizeToStatusBar: (() -> Void)?
    override func miniaturize(_ sender: Any?) { minimizeToStatusBar?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var store: AppStore!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var applicationLogo: NSImage?
    var exitAlertPresenter: ((NSAlert) -> NSApplication.ModalResponse)?
    var onWillTerminate: (() -> Void)?
    private var exitRequestedByClose = false
    private var showingExitConfirmation = false
    var passiveTesting: Bool { CommandLine.arguments.contains("--passive-test") }
    let statusPopover = NSPopover()
    let outsideClicks = PopoverOutsideClickMonitor()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if argumentValue("--appearance") == "dark" { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        else if argumentValue("--appearance") == "light" { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        let directory = argumentValue("--state-dir").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelManager")
        store = AppStore(stateDirectory: directory)
        store.onLanguageChange = { [weak self] in self?.refreshLanguage() }
        if passiveTesting { NSApplication.shared.setActivationPolicy(.accessory) }
        applyDockIcon()
        DispatchQueue.main.async { [weak self] in self?.applyDockIcon() }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let capturing = argumentValue("--capture-dir") != nil
        let captureWidth = CGFloat(Double(argumentValue("--capture-width") ?? "1440") ?? 1440)
        let captureHeight = CGFloat(Double(argumentValue("--capture-height") ?? "1024") ?? 1024)
        // Default to the common 1280×800 desktop size, capped at 85% of the visible screen and never below minSize.
        let contentSize = NSSize(width: capturing ? captureWidth : max(980, min(1280, (screen.width * 0.85).rounded())),
                                 height: capturing ? captureHeight : max(740, min(800, (screen.height * 0.85).rounded())))
        window = ManagerWindow(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.delegate = self
        (window as? ManagerWindow)?.minimizeToStatusBar = { [weak self] in self?.hideMainWindow() }
        store.showMainWindow = { [weak self] in self?.showMainWindow() }
        store.showSettings = { [weak self] in self?.showSettings() }
        window.title = L10n.text("模型管理"); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 980, height: 740); window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        let view = NSHostingView(rootView: MainView(store: store, services: store.services)); window.contentView = view
        if passiveTesting {
            window.setFrameOrigin(NSPoint(x: screen.maxX + 200, y: screen.minY + 100)); window.orderFront(nil)
        } else {
            // NSWindow.center() sits above the midline; place the window at the true center of the visible area.
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: (screen.midX - frame.width / 2).rounded(), y: (screen.midY - frame.height / 2).rounded()))
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        }
        makeMenu(); makeStatusBar()
        if !CommandLine.arguments.contains("--documentation-ui") { store.services.beginMonitoring(); store.scan(); store.beginResourceMonitoring() }
        if let task = argumentValue("--resume-download-job"), UUID(uuidString: task) != nil, store.downloads.jobs.contains(where: { $0.id == task }) {
            store.downloads.showTask(task); store.tab = .downloads; store.downloads.resume(task)
        }
        if let path = argumentValue("--launch-local-model"), argumentValue("--capture-dir") == nil {
            Task {
                for _ in 0..<150 { if self.store.inventory != nil && !self.store.scanning { break }; try? await Task.sleep(nanoseconds: 200_000_000) }
                guard let kind = EngineKind(rawValue: argumentValue("--launch-engine") ?? "mlx"),
                      let engine = self.store.engines.first(where: { $0.kind == kind }),
                      let model = self.store.models.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }),
                      let port = Int(argumentValue("--launch-port") ?? "8083"), (1024...65535).contains(port) else { self.store.message = "未找到完整模型或有效启动配置"; return }
                self.store.launch(model: model, engine: engine)
                self.store.inputMode = InputMode(rawValue: argumentValue("--launch-mode") ?? "multimodal") ?? .multimodal
                self.store.port = String(port); self.store.context = 32768
                guard self.store.canStart else { self.store.message = self.store.portConflict ?? self.store.nativeInputReason ?? "当前模型服务暂不能启动"; return }
                self.store.start()
                if let spec = self.store.selectedService { self.store.showService(spec) }
            }
        }
        if store.gateway.settings.enabled && !passiveTesting { store.gateway.start(store: store) }
        if CommandLine.arguments.contains("--documentation-ui") {
            Task { do { try await DocumentationScreens.run(self) } catch { fputs("DOCUMENTATION CAPTURE FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }
        } else if CommandLine.arguments.contains("--popover-checks") {
            Task { do { try await PopoverChecks.run(self) } catch { fputs("POPOVER CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }
        } else if CommandLine.arguments.contains("--close-lifecycle-checks") {
            Task { do { try await CloseChecks.run(self) } catch { fputs("CLOSE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }
        } else if CommandLine.arguments.contains("--restore-splash") { Task { await restoreSplashService() } }
        else if capturing { Task { await captureScreens() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { applyDockIcon() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        guard window.attachedSheet == nil else { return false }
        if store.windowCloseBehavior == .keepRunning { hideMainWindow() }
        else { exitRequestedByClose = true; NSApplication.shared.terminate(nil) }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === settingsWindow, store.hiddenToStatusBar {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
    @objc func hideMainWindow() {
        guard window.attachedSheet == nil else { return }
        statusPopover.performClose(nil); window.orderOut(nil); store.hiddenToStatusBar = true
        NSApplication.shared.setActivationPolicy(settingsWindow?.isVisible == true ? .regular : .accessory)
    }
    @objc func showMainWindow() {
        statusPopover.performClose(nil); NSApplication.shared.setActivationPolicy(.regular)
        applyDockIcon()
        if passiveTesting { window.orderFront(nil) }
        else { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
        store.hiddenToStatusBar = false
    }
    @objc func showSettings() {
        statusPopover.performClose(nil)
        if settingsWindow == nil {
            let preferences = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            preferences.title = L10n.text("设置"); preferences.isReleasedWhenClosed = false; preferences.delegate = self
            preferences.contentView = NSHostingView(rootView: PreferencesView(store: store, close: { [weak self] in self?.settingsWindow?.performClose(nil) }))
            preferences.backgroundColor = .windowBackgroundColor
            if passiveTesting {
                let screen = NSScreen.main?.visibleFrame ?? .zero
                preferences.setFrameOrigin(NSPoint(x: screen.maxX + 200, y: screen.minY + 100))
            } else { preferences.center() }
            settingsWindow = preferences
        }
        NSApplication.shared.setActivationPolicy(.regular)
        applyDockIcon()
        if passiveTesting { settingsWindow?.orderFront(nil) }
        else { settingsWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    func applyDockIcon() {
        if applicationLogo == nil, let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { applicationLogo = NSImage(contentsOf: icon) }
        if let icon = applicationLogo { icon.isTemplate = false; NSApplication.shared.applicationIconImage = icon }
    }
    func makeStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: L10n.text("模型管理"))
            icon?.isTemplate = true; button.image = icon; button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(toggleStatusPopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let controller = NSHostingController(rootView: StatusBarPanel(store: store, services: store.services, monitor: store.resources, performance: store.performance))
        controller.sizingOptions = [.preferredContentSize]
        statusPopover.contentViewController = controller; statusPopover.behavior = .transient; statusPopover.delegate = self; statusPopover.animates = false
        statusPopover.appearance = NSApplication.shared.appearance
        statusPopover.contentSize = NSSize(width: 390, height: 600)
        store.resources.onChange = { [weak self] in self?.updateStatusBar() }; updateStatusBar()
    }
    func updateStatusBar() {
        guard let button = statusItem?.button else { return }
        let cpu = store.resources.system?.cpu.map { String(format: "%.0f%%", $0) } ?? "—"
        let memory = store.resources.system.map { String(format: "%.0fG", Double($0.memoryUsed) / 1_073_741_824) } ?? "—"
        button.title = " CPU \(cpu) · \(memory)"
        button.toolTip = L10n.text("模型管理 · CPU \(cpu) · 内存 \(memory) · 点击查看磁盘与模型服务")
    }
    @objc func toggleStatusPopover() {
        guard let button = statusItem.button else { return }
        if statusPopover.isShown { statusPopover.performClose(nil) }
        else { statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); outsideClicks.start(popover: statusPopover, button: button) }
    }
    func popoverDidClose(_ notification: Notification) { outsideClicks.stop() }
    func refreshLanguage() {
        makeMenu(); window?.title = L10n.text("模型管理"); settingsWindow?.title = L10n.text("设置"); updateStatusBar()
    }
    func applicationWillTerminate(_ notification: Notification) {
        outsideClicks.stop()
        store.resources.end(); store.performance.cancel()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        onWillTerminate?()
    }
    func makeExitAlert() -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.text("确认退出模型管理？")
        alert.informativeText = L10n.text("退出后，资源监测停止，下载任务暂停。已启动的模型服务继续运行，下次打开仍可管理。")
        alert.addButton(withTitle: L10n.text("确认退出")); alert.addButton(withTitle: L10n.text("取消"))
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        return alert
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let fromWindowClose = exitRequestedByClose; exitRequestedByClose = false
        if showingExitConfirmation { return .terminateCancel }
        if store.maintaining || store.installation.running || store.multiModel?.running == true {
            store.message = "请等待引擎安装、清理或模型加载完成后退出。"
            return .terminateCancel
        }
        if fromWindowClose || (argumentValue("--capture-dir") == nil && store.services.records.contains(where: { $0.pid != nil })) {
            showingExitConfirmation = true
            let alert = makeExitAlert()
            let response = exitAlertPresenter?(alert) ?? alert.runModal()
            showingExitConfirmation = false
            guard response == .alertFirstButtonReturn else { return .terminateCancel }
        }
        if store.downloads.activeID != nil { store.downloads.pause(); store.downloads.save() }
        return .terminateNow
    }
    func makeMenu() {
        let main = NSMenu(); let app = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = app
        app.addItem(withTitle: L10n.text("关于模型管理"), action: #selector(about), keyEquivalent: "").target = self
        app.addItem(withTitle: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator()); app.addItem(withTitle: L10n.text("退出模型管理"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let file = NSMenu(title: L10n.text("文件")); let fileItem = NSMenuItem(title: L10n.text("文件"), action: nil, keyEquivalent: ""); fileItem.submenu = file
        file.addItem(withTitle: L10n.text("添加模型目录…"), action: #selector(addFolder), keyEquivalent: "o").target = self
        file.addItem(withTitle: L10n.text("重新扫描"), action: #selector(rescan), keyEquivalent: "r").target = self; main.addItem(fileItem)
        file.addItem(withTitle: L10n.text("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: L10n.text("编辑")); let editItem = NSMenuItem(title: L10n.text("编辑"), action: nil, keyEquivalent: ""); editItem.submenu = edit
        edit.addItem(withTitle: L10n.text("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"); edit.addItem(withTitle: L10n.text("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edit.addItem(withTitle: L10n.text("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"); edit.addItem(withTitle: L10n.text("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); main.addItem(editItem)
        let view = NSMenu(title: L10n.text("视图")); let viewItem = NSMenuItem(title: L10n.text("视图"), action: nil, keyEquivalent: ""); viewItem.submenu = view
        for (index, tab) in AppTab.allCases.enumerated() { let item = NSMenuItem(title: L10n.text(tab.rawValue), action: #selector(selectTab(_:)), keyEquivalent: String(index + 1)); item.tag = index; item.target = self; view.addItem(item) }
        main.addItem(viewItem); NSApplication.shared.mainMenu = main
        let windows = NSMenu(title: L10n.text("窗口")); let windowsItem = NSMenuItem(title: L10n.text("窗口"), action: nil, keyEquivalent: ""); windowsItem.submenu = windows
        windows.addItem(withTitle: L10n.text("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(windowsItem); NSApplication.shared.windowsMenu = windows
    }
    @objc func about() { NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: L10n.text("模型管理"), .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", .credits: NSAttributedString(string: L10n.text("模型与下载任务管理、命令启动和统一网关"))]) }
    @objc func addFolder() { store.addLocation() }
    @objc func rescan() { store.scan() }
    @objc func selectTab(_ sender: NSMenuItem) { store.tab = AppTab.allCases[sender.tag] }

    func capture(_ name: String, folder: URL) throws {
        func hosting(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("HostingView") { return view }
            for child in view.subviews { if let result = hosting(child) { return result } }
            return nil
        }
        let sheet = window.attachedSheet?.contentView
        let candidate = name.hasPrefix("statusbar") ? statusPopover.contentViewController?.view : name.hasPrefix("settings") ? settingsWindow?.contentView : name.hasSuffix("-preview") ? sheet.flatMap(hosting) ?? sheet : window.contentView
        guard let content = candidate else { throw LaunchError.message("No window content") }
        try captureView(content, name: name, folder: folder)
    }
    func captureView(_ content: NSView, name: String, folder: URL) throws {
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw LaunchError.message("Unable to capture rendered view") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        var export = bitmap
        if name.hasPrefix("exit-confirmation"),
           let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let graphics = NSGraphicsContext(bitmapImageRep: opaque) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
                let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                image.addRepresentation(bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh), from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState(); export = opaque
        }
        guard let data = export.representation(using: .png, properties: [:]) else { throw LaunchError.message("Unable to encode screenshot") }
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
    func scrollDetailsToBottom() {
        guard let content = window.contentView else { return }
        @MainActor func scrolls(_ view: NSView) -> [NSScrollView] { if let scroll = view as? NSScrollView { return [scroll] }; return view.subviews.flatMap(scrolls) }
        guard let scroll = scrolls(content).filter({ $0.bounds.height > 400 && $0.convert($0.bounds, to: content).minX > 300 }).max(by: { $0.bounds.height < $1.bounds.height }), let document = scroll.documentView else { return }
        let bottom = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func captureScreens() async {
        do {
            let folder = URL(fileURLWithPath: argumentValue("--capture-dir")!)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for _ in 0..<120 { if store.inventory != nil && !store.scanning { break }; try await Task.sleep(nanoseconds: 250_000_000) }
            guard store.inventory != nil else { throw LaunchError.message("Inventory did not finish") }
            if CommandLine.arguments.contains("--version-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Version checks require isolated state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await EngineVersionChecks.exercise(store: store, root: root) { name in
                    try await Task.sleep(nanoseconds: 400_000_000); try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--components-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Component checks require isolated state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await ServiceComponentChecks.exercise(store: store, root: root) { name in
                    try await Task.sleep(nanoseconds: 400_000_000); try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--identity-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Identity checks require isolated state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await ModelIdentityChecks.exercise(store: store, root: root) { name in
                    try await Task.sleep(nanoseconds: 400_000_000); try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--release-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Release checks require isolated state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await ReleaseChecks.exercise(store: store, root: root) { name in
                    try await Task.sleep(nanoseconds: 450_000_000); try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--startup-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Startup checks require empty isolated state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await StartupChecks.exercise(store: store, root: root) { name in
                    try await Task.sleep(nanoseconds: 400_000_000)
                    if name == "mlx-vlm-startup" { self.scrollDetailsToBottom(); try await Task.sleep(nanoseconds: 300_000_000) }
                    try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--download-task-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.downloads.jobs.isEmpty else { throw LaunchError.message("Download checks require isolated empty state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await DownloadTaskChecks.exercise(store: store, root: root) { name in
                    if name.hasPrefix("statusbar") { self.toggleStatusPopover() }
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if name.hasPrefix("statusbar") {
                        guard self.statusPopover.isShown else { throw LaunchError.message("Download popover did not open") }
                    }
                    try self.capture(name, folder: folder)
                    if name.hasPrefix("statusbar") {
                        StatusDownloads(store: self.store, downloads: self.store.downloads).manage()
                        for _ in 0..<40 {
                            if !self.statusPopover.isShown { break }
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard self.window.isVisible, self.store.tab == .downloads, !self.statusPopover.isShown else { throw LaunchError.message("Download management did not reopen") }
                    }
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--model-update-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Model update checks require isolated empty state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await ModelUpdateChecks.exercise(store: store, root: root) { name in
                    for _ in 0..<40 { if self.window.attachedSheet != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--modality-live-ui-checks") {
                let actual = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelManager").resolvingSymlinksInPath()
                guard let path = argumentValue("--state-dir"), URL(fileURLWithPath: path).resolvingSymlinksInPath() != actual else { throw LaunchError.message("Live preview requires a separate copied state directory") }
                let before = store.services.records.filter { $0.pid != nil }
                var evidence: [[String: Any]] = []
                for kind in ["splash", "llama"] {
                    guard let spec = before.first(where: { $0.engineID == kind }), let model = store.models.first(where: { $0.id == spec.modelID }) else { continue }
                    store.chooseEngine(kind); store.port = String(spec.port); store.selectedModels[kind] = model.id; store.inputMode = spec.inputMode ?? .automatic; store.projectorPath = spec.projectorPath ?? ""; store.tab = .engines
                    await store.services.refresh(); try await Task.sleep(nanoseconds: 500_000_000)
                    scrollDetailsToBottom(); try await Task.sleep(nanoseconds: 300_000_000)
                    try capture(kind + "-actual-startup", folder: folder)
                    let capability = store.serviceCapabilities(spec), intrinsic = store.modelCapabilities(model)
                    evidence.append(["engine": kind, "port": spec.port, "pid": spec.pid ?? 0, "modelBadge": intrinsic.badgeTitle, "modelInputs": intrinsic.inputs, "serviceBadge": capability.badgeTitle, "serviceInputs": capability.inputs, "actualInputsKnown": capability.known])
                    if kind == "llama" { store.tab = .models; store.selectedFileID = model.id; try await Task.sleep(nanoseconds: 400_000_000); try capture("llama-actual-model", folder: folder) }
                }
                for spec in before { guard spec.pid.map({ processStartTime($0) == spec.processStart }) == true else { throw LaunchError.message("Original model process changed") } }
                try ConnectionChecks.require(evidence.count == 2 && evidence.allSatisfy { $0["actualInputsKnown"] as? Bool == true }, "Actual model capabilities unavailable")
                try ConnectionFiles.json(["result": "passed", "models": evidence, "realServicesPreserved": true, "readOnlyPreview": true]).write(to: folder.appendingPathComponent("result.json"))
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--modality-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Modality checks require isolated empty state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await ModalityChecks.exercise(store: store, root: root) { name in
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if name.hasSuffix("-preview") { for _ in 0..<40 { if self.window.attachedSheet != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) } }
                    else if self.store.tab == .engines, let content = self.window.contentView {
                        @MainActor func scrolls(_ view: NSView) -> [NSScrollView] { if let scroll = view as? NSScrollView { return [scroll] }; return view.subviews.flatMap(scrolls) }
                        if let scroll = scrolls(content).filter({ $0.bounds.height > 400 && $0.convert($0.bounds, to: content).minX > 300 }).max(by: { $0.bounds.height < $1.bounds.height }), let document = scroll.documentView {
                            let bottom = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView); try await Task.sleep(nanoseconds: 300_000_000)
                        }
                    }
                    try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--gateway-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Gateway checks require isolated empty state") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try await GatewayChecks.exercise(store: store, root: root) { name in
                    if name.hasSuffix("-preview") { for _ in 0..<40 { if self.window.attachedSheet != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) } }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if ["model-multimodal-mode", "gateway-external-services"].contains(name), let content = self.window.contentView {
                        @MainActor func scrolls(_ view: NSView) -> [NSScrollView] {
                            if let scroll = view as? NSScrollView { return [scroll] }
                            return view.subviews.flatMap(scrolls)
                        }
                        if let scroll = scrolls(content).filter({ $0.bounds.height > 400 && $0.convert($0.bounds, to: content).minX > 300 }).max(by: { $0.bounds.height < $1.bounds.height }), let document = scroll.documentView {
                            let bottom = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                            try await Task.sleep(nanoseconds: 300_000_000)
                        }
                    }
                    try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }; return
            }
            if CommandLine.arguments.contains("--model-management-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Model management UI checks require an empty isolated state directory") }
                let root = folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString)
                try ConnectionFiles.privateDirectory(root)
                try await ModelManagementChecks.exercise(store: store, root: root) { name in
                    if name.hasSuffix("-preview") {
                        for _ in 0..<30 { if self.window.attachedSheet != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                        guard self.window.attachedSheet != nil else { throw LaunchError.message("Expected update sheet was not presented") }
                    }
                    try await Task.sleep(nanoseconds: 500_000_000); try self.capture(name, folder: folder)
                }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }
                return
            }
            if CommandLine.arguments.contains("--engine-service-ui-checks") {
                guard argumentValue("--state-dir") != nil, store.services.records.isEmpty else { throw LaunchError.message("Engine service UI checks require an empty isolated state directory") }
                do {
                    let fixture = try await EngineServiceChecks.prepare(store: store, root: folder.appendingPathComponent("fixtures").appendingPathComponent(UUID().uuidString))
                    try await EngineServiceChecks.exercise(store: store, fixture: fixture) { name in
                        try await Task.sleep(nanoseconds: 400_000_000); try self.capture(name, folder: folder)
                    }
                } catch { await EngineServiceChecks.cleanup(store: store); throw error }
                if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }
                return
            }
            if CommandLine.arguments.contains("--capture-monitor") {
                for _ in 0..<40 { if store.resources.system?.cpu != nil { break }; try await Task.sleep(nanoseconds: 250_000_000) }
                guard store.resources.system?.cpu != nil else { throw LaunchError.message("Resource samples did not arrive") }
            }
            try await Task.sleep(nanoseconds: 700_000_000)
            for (index, tab) in AppTab.allCases.enumerated() {
                let menuItem = NSMenuItem(); menuItem.tag = index; selectTab(menuItem)
                try await Task.sleep(nanoseconds: 400_000_000); try capture(tab == .engines ? "engines" : tab == .models ? "models" : tab == .services ? "services" : tab == .downloads ? "downloads" : "monitor", folder: folder)
            }
            if CommandLine.arguments.contains("--capture-monitor") {
                func scrollView(_ view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    for child in view.subviews { if let scroll = scrollView(child) { return scroll } }
                    return nil
                }
                if let scroll = window.contentView.flatMap(scrollView), let document = scroll.documentView {
                    let bottom = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(nanoseconds: 300_000_000); try capture("monitor-performance", folder: folder)
                }
                if let modelID = store.performance.records.first?.target.modelID, store.models.contains(where: { $0.id == modelID }) {
                    store.tab = .models; store.selectedFileID = modelID
                    try await Task.sleep(nanoseconds: 300_000_000); try capture("model-performance", folder: folder)
                }
            }
            if let special = store.models.first(where: { $0.prismRequired == true && $0.kind == .language }) {
                store.tab = .models; store.selectedFileID = special.id
                try await Task.sleep(nanoseconds: 300_000_000); try capture("model-special", folder: folder)
            }
            if CommandLine.arguments.contains("--capture-connections") {
                guard let target = store.connectionTargets.first else { throw LaunchError.message("No available connection target") }
                store.tab = .services
                if target.id.hasPrefix("external:") { store.selectedExternal = target.port }
                else { store.selectedExternal = nil; store.selectedServiceID = store.services.records.first { $0.port == target.port }?.id }
                try await Task.sleep(nanoseconds: 300_000_000); try capture("services-connect", folder: folder)
                store.connections.present(port: target.port, targets: store.connectionTargets)
                for _ in 0..<100 { if !store.connections.discovering { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                try await Task.sleep(nanoseconds: 400_000_000); try capture("connections-preview", folder: folder)
                if CommandLine.arguments.contains("--connection-ui-checks") {
                    let work = folder.appendingPathComponent("test-working-directory")
                    try ConnectionFiles.privateDirectory(work); store.connections.project = work.path
                    var connectedClients: [String] = []
                    for client in CodingClient.allCases where client.contextRequirement(store.connections.context) == nil && store.connections.installations.contains(where: { $0.id == client && $0.executable != nil }) {
                        store.connections.connect(client, store: store, launch: false)
                        for _ in 0..<120 { if !store.connections.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                        guard !store.connections.busy, store.connections.error == nil, store.connections.lastConnection?.client == client else {
                            throw LaunchError.message("Client connection UI failed: " + (store.connections.error ?? client.title))
                        }
                        connectedClients.append(client.title)
                    }
                    try ConnectionFiles.json(["result": "passed", "connectedClients": connectedClients, "installedClients": store.connections.installations.compactMap { $0.executable == nil ? nil : $0.id.title },
                        "incompatibleClients": CodingClient.allCases.compactMap { client in client.contextRequirement(store.connections.context).map { "\(client.title): " + $0 } },
                        "serviceModel": target.model, "port": target.port, "serviceIdentityPreserved": processStartTime(target.pid) == target.birth])
                        .write(to: folder.appendingPathComponent("connection-ui-checks.json"))
                }
                store.connections.draft = nil
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if CommandLine.arguments.contains("--capture-operations") {
                store.chooseEngine("llama"); store.tab = .engines; store.prepareMultiModel()
                for _ in 0..<40 { if !store.preparingMulti { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                guard let draft = store.multiModel else { throw LaunchError.message("Multi-model preview did not open") }
                draft.selected = Set(draft.choices.prefix(2).map(\.id))
                guard draft.selected.count == 2 && draft.ports?.count == 2 else { throw LaunchError.message("Multi-model selection or port allocation failed") }
                try await Task.sleep(nanoseconds: 400_000_000); try capture("multi-model-preview", folder: folder)
                store.multiModel = nil; try await Task.sleep(nanoseconds: 300_000_000)
                store.chooseEngine("splash"); store.checkInstall()
                for _ in 0..<120 { if store.installation.checking == nil { break }; try await Task.sleep(nanoseconds: 250_000_000) }
                guard let plan = store.installation.plan, !plan.release.version.isEmpty else { throw LaunchError.message(store.installation.message ?? "Installation preview did not open") }
                if servicesActive("splash") { guard !plan.blockers.isEmpty else { throw LaunchError.message("Running service did not block engine update") } }
                try await Task.sleep(nanoseconds: 400_000_000); try capture("install-preview", folder: folder); store.installation.plan = nil
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": ["two-model selection", "separate available ports", "official version metadata", "concrete install preview", "running engine update blocked"]], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("operation-interactions.json"))
            }
            if CommandLine.arguments.contains("--capture-details") {
                store.chooseEngine("lmstudio"); store.tab = .engines; store.prepareMaintenance(.residues)
                for _ in 0..<80 { if !store.preparingMaintenance { break }; try await Task.sleep(nanoseconds: 250_000_000) }
                try await Task.sleep(nanoseconds: 500_000_000); try capture("cleanup-preview", folder: folder); store.maintenancePlan = nil
                store.tab = .downloads; store.downloads.address = "https://huggingface.co/Qwen/Qwen3-0.6B"
                let listing = try await ModelCatalog.listing(store.downloads.address, token: "")
                store.downloads.listing = listing; store.downloads.selected = ModelCatalog.suggested(listing)
                try await Task.sleep(nanoseconds: 500_000_000); try capture("download-files", folder: folder)
            }
            store.chooseEngine("splash")
            store.tab = .engines; store.port = "0"
            try await Task.sleep(nanoseconds: 300_000_000)
            guard !store.canStart else { throw LaunchError.message("Invalid port enabled start") }
            try capture("invalid-port", folder: folder); store.port = "8000"
            if CommandLine.arguments.contains("--capture-ports") {
                let conflictPort = NetworkProbe.portOccupied(8000) ? 8000 : 8081
                store.chooseEngine("mlx"); store.port = String(conflictPort)
                await store.services.refresh()
                guard !store.canStart, store.portConflict != nil else { throw LaunchError.message("Occupied port not blocked for selected MLX engine") }
                try await Task.sleep(nanoseconds: 300_000_000); try capture("port-conflict", folder: folder)
                store.useFreePort()
                guard store.portConflict == nil, store.parsedPort != conflictPort, store.parsedPort != 8080 else { throw LaunchError.message("Automatic free port failed") }
                try await Task.sleep(nanoseconds: 300_000_000); try capture("port-resolved", folder: folder)
                store.tab = .services; store.selectedExternal = 8081
                try await Task.sleep(nanoseconds: 300_000_000); try capture("port-identity", folder: folder)
                let proof: [String: Any] = ["occupied_port": conflictPort, "resolved_port": store.parsedPort ?? 0, "start_blocked_on_conflict": true, "external_8081_engine": store.services.external.first { $0.port == 8081 }?.engineID ?? "unidentified"]
                try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("port-interactions.json"))
            }
            store.tab = .models; store.search = "Bonsai"
            guard store.filteredModels.allSatisfy({ ($0.name + $0.format + $0.path).localizedCaseInsensitiveContains("Bonsai") }) else { throw LaunchError.message("Search failed") }
            guard let selected = store.selectedFile, store.filteredModels.contains(where: { $0.id == selected.id }), store.selectedFileID == selected.id else { throw LaunchError.message("Search detail selection failed") }
            try await Task.sleep(nanoseconds: 300_000_000); try capture("search", folder: folder)
            store.search = ""; store.tab = .engines
            if CommandLine.arguments.contains("--capture-monitor") {
                let sampled = store.resources.system?.sampledAt
                window.miniaturize(nil)
                guard !window.isVisible && store.hiddenToStatusBar && statusItem.isVisible && NSApplication.shared.activationPolicy() == .accessory else { throw LaunchError.message("Minimize did not leave a resident menu-bar app") }
                try await Task.sleep(nanoseconds: 3_500_000_000)
                guard store.resources.system?.sampledAt != sampled else { throw LaunchError.message("Resource monitoring stopped while hidden") }
                toggleStatusPopover(); try await Task.sleep(nanoseconds: 500_000_000)
                guard statusPopover.isShown else { throw LaunchError.message("Menu-bar popover failed to open") }
                try capture("statusbar", folder: folder)
                showMainWindow()
                guard window.isVisible && !store.hiddenToStatusBar && NSApplication.shared.activationPolicy() == .regular else { throw LaunchError.message("Main window did not reopen") }
                window.performClose(nil)
                guard !window.isVisible && store.hiddenToStatusBar && statusItem.isVisible else { throw LaunchError.message("Close did not leave a resident app") }
                _ = applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
                guard window.isVisible && !store.hiddenToStatusBar else { throw LaunchError.message("Dock reopen failed") }
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": ["native menu-bar item", "yellow minimize", "monitor updates while hidden", "menu-bar popover", "open main window", "red close", "Dock reopen"]], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("statusbar-lifecycle.json"))
            }
            try JSONEncoder().encode(store.inventory).write(to: folder.appendingPathComponent("inventory.json"))
            print("UI capture and interaction checks passed: \(folder.path)")
            if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }
        } catch { fputs("Capture failed: \(error.localizedDescription)\n", stderr); if CommandLine.arguments.contains("--capture-only") { exit(1) } }
    }
    func servicesActive(_ engineID: String) -> Bool { store.services.records.contains { $0.engineID == engineID && $0.pid != nil } }
}

@main
enum Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--child-exec") { ChildExecutor.run(arguments: Array(args.dropFirst(index + 1))) }
        if args.contains("--launch-associated-test") { Task { do { try await ReleaseChecks.startAssociated() } catch { fputs("ASSOCIATED TEST FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if let path = argumentValue("--validate-connection") {
            Task { do { try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: path)); exit(0) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) } }
            CFRunLoopRun(); return
        }
        if args.contains("--scan") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { print(String(decoding: try encoder.encode(Scanner.scan()), as: UTF8.self)) } catch { fputs("\(error)\n", stderr); exit(1) }; return
        }
        if args.contains("--self-test") { selfTest(); return }
        if args.contains("--localization-checks") { do { try LocalizationChecks.run() } catch { fputs("LOCALIZATION CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) }; return }
        if args.contains("--live-context-checks") || argumentValue("--repair-connection-context") != nil {
            Task { do { try await ConnectionLive.run(repairPort: argumentValue("--repair-connection-context").flatMap(Int.init)); exit(0) }
                catch { fputs("CONTEXT REPAIR FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }
            CFRunLoopRun(); return
        }
        if args.contains("--component-checks") { Task { do { try await ServiceComponentChecks.run(); exit(0) } catch { fputs("COMPONENT CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--identity-checks") { Task { do { try await ModelIdentityChecks.run(); exit(0) } catch { fputs("IDENTITY CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--release-checks") { Task { do { try await ReleaseChecks.run(); exit(0) } catch { fputs("RELEASE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--distribution-checks") { Task { do { try await DistributionChecks.run(); exit(0) } catch { fputs("DISTRIBUTION CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--version-checks") { Task { do { try await EngineVersionChecks.run(); exit(0) } catch { fputs("VERSION CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--connection-checks") { Task { do { try await ConnectionChecks.run(); exit(0) } catch { fputs("CONNECTION CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--gateway-checks") { Task { do { try await GatewayChecks.run(); exit(0) } catch { fputs("GATEWAY CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--download-task-checks") { Task { do { try await DownloadTaskChecks.run(); exit(0) } catch { fputs("DOWNLOAD TASK CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--startup-checks") { Task { do { try await StartupChecks.run(); exit(0) } catch { fputs("STARTUP CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--model-update-checks") { Task { do { try await ModelUpdateChecks.run(); exit(0) } catch { fputs("MODEL UPDATE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--modality-checks") { Task { do { try await ModalityChecks.run(); exit(0) } catch { fputs("MODALITY CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--gateway-live-checks") { Task { do { try await GatewayLive.run(); exit(0) } catch { fputs("GATEWAY LIVE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--engine-service-checks") { Task { do { try await EngineServiceChecks.run(); exit(0) } catch { fputs("ENGINE SERVICE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--model-management-checks") { Task { do { try await ModelManagementChecks.run(); exit(0) } catch { fputs("MODEL MANAGEMENT CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--context-restart-checks") { Task { do { try await ContextRestartChecks.run(); exit(0) } catch { fputs("CONTEXT RESTART CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--splash-checks") { do { try SplashChecks.run() } catch { fputs("SPLASH CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) }; return }
        if args.contains("--feature-checks") { Task { do { try await FeatureChecks.run(); exit(0) } catch { fputs("FEATURE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--monitor-checks") { Task { do { try await MonitorChecks.run(); exit(0) } catch { fputs("MONITOR CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--operation-checks") { Task { do { try await OperationChecks.run(); exit(0) } catch { fputs("OPERATION CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--port-checks") { Task { do { try await PortChecks.run(); exit(0) } catch { fputs("PORT CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--live-multi-smoke") { Task { do { try await OperationChecks.liveMulti(); exit(0) } catch { fputs("LIVE MULTI FAILED: \(error.localizedDescription)\n", stderr); exit(1) } }; CFRunLoopRun(); return }
        if args.contains("--smoke-service") { smokeService(); CFRunLoopRun(); return }
        let app = NSApplication.shared; app.setActivationPolicy(.regular); let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    static func selfTest() {
        let inventory = Scanner.scan()
        do {
            guard let splash = inventory.engines.first(where: { $0.kind == .splash }),
                  let splashModel = inventory.models.first(where: { $0.format.hasPrefix("Splash") && $0.complete }),
                  let prism = inventory.engines.first(where: { $0.kind == .prism }),
                  let bonsai = inventory.models.first(where: { $0.format.contains("PQ2") && $0.complete }) else { throw LaunchError.message("Expected local models missing") }
            let plan = try LaunchBuilder.plan(engine: splash, model: splashModel, port: 8765)
            guard plan.environment["HF_HUB_CACHE"]?.hasSuffix("hf-cache/hub") == true, plan.environment["HF_HUB_OFFLINE"] == "1" else { throw LaunchError.message("Incorrect offline cache path") }
            _ = try LaunchBuilder.plan(engine: prism, model: bonsai, port: 8766)
            for badPort in [0, 80, 65536] {
                do { _ = try LaunchBuilder.plan(engine: splash, model: splashModel, port: badPort); throw LaunchError.message("Invalid port accepted") }
                catch LaunchError.message(let message) where message.contains("端口") { }
            }
            do { _ = try LaunchBuilder.plan(engine: splash, model: bonsai, port: 8765); throw LaunchError.message("Incompatible model accepted") }
            catch LaunchError.message(let message) where message.contains("兼容") { }
            let primary = inventory.models.filter { $0.kind == .language }
            guard primary.count >= 6, primary.allSatisfy(\.complete) else { throw LaunchError.message("Primary model inventory is incomplete") }
            print("PASS: \(primary.count) primary models, \(inventory.models.count) total entries; compatibility, invalid ports, offline cache configuration verified")
        } catch { fputs("SELF TEST FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func smokeService() {
        Task {
            let folder = URL(fileURLWithPath: argumentValue("--state-dir") ?? "/private/tmp/model-manager-smoke")
            let controller = ServiceController(stateDirectory: folder)
            var spec: ServiceSpec?
            do {
                let inventory = await Task.detached { Scanner.scan() }.value
                let kind = EngineKind(rawValue: argumentValue("--smoke-engine") ?? "prism") ?? .prism
                guard let engine = inventory.engines.first(where: { $0.kind == kind }), let model = inventory.models.first(where: { $0.kind == .language && $0.compatible(with: engine) && (kind != .prism || $0.format.contains("PQ2")) }) else { throw LaunchError.message("Compatible model unavailable") }
                guard let port = (18765...18785).first(where: { !NetworkProbe.portOccupied($0) }) else { throw LaunchError.message("No free smoke test port") }
                spec = try controller.start(engine: engine, model: model, port: port, context: 2048)
                var ready = false
                for _ in 0..<90 { await controller.refresh(); if controller.status(spec!) == .running { ready = true; break }; if controller.status(spec!) == .failed { throw LaunchError.message(controller.log(spec!.id)) }; try await Task.sleep(nanoseconds: 1_000_000_000) }
                guard ready else { throw LaunchError.message("Service did not become ready: \(controller.log(spec!.id))") }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!); request.httpMethod = "POST"; request.timeoutInterval = 45; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let reportedName = await NetworkProbe.models(port: port).models.first ?? model.repository ?? model.name
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": reportedName, "messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 8, "temperature": 0])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let choices = json["choices"] as? [[String: Any]], !choices.isEmpty else { throw LaunchError.message("Inference API failed") }
                let restored = ServiceController(stateDirectory: folder)
                await restored.refresh()
                guard let restoredSpec = restored.records.first(where: { $0.id == spec!.id }), restoredSpec.pid != nil, restored.status(restoredSpec) == .running else { throw LaunchError.message("Persisted service ownership did not restore") }
                try restored.stop(restoredSpec)
                for _ in 0..<30 { await restored.refresh(); if !NetworkProbe.portOccupied(port) && restored.records.first(where: { $0.id == spec!.id })?.pid == nil { break }; try await Task.sleep(nanoseconds: 300_000_000) }
                guard !NetworkProbe.portOccupied(port) else { throw LaunchError.message("Service port remained open after stop") }
                let report: [String: Any] = ["result": "passed", "engine": engine.name, "model": model.name, "port": port, "checks": ["start", "readiness", "model endpoint", "real inference", "restore persisted management", "stop", "port released"]]
                let result = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]); try result.write(to: folder.appendingPathComponent("smoke-result.json")); print(String(decoding: result, as: UTF8.self)); exit(0)
            } catch { if let spec { try? controller.stop(spec); try? await Task.sleep(nanoseconds: 4_500_000_000) }; fputs("SMOKE TEST FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
}
