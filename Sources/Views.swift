import SwiftUI
import AppKit

/// Text sizes follow the macOS HIG text styles; views use these instead of ad-hoc point sizes.
/// Symbol (icon) sizes are independent and stay in the views.
enum TypeScale {
    static let display: CGFloat = 26 // detail hero title (Large Title)
    static let title: CGFloat = 22   // page title (Title 1)
    static let section: CGFloat = 17 // section heading (Title 2)
    static let body: CGFloat = 13    // body, row titles (Body / Headline)
    static let callout: CGFloat = 12 // secondary text (Callout)
    static let caption: CGFloat = 11 // labels and notes (Caption)
}

enum Theme {
    static let accent = Color(red: 0.32, green: 0.30, blue: 0.94)
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color { Color(nsColor: NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }
    static let background = adaptive(NSColor(red: 0.976, green: 0.976, blue: 0.992, alpha: 1), NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1))
    static let sidebar = adaptive(NSColor(red: 0.965, green: 0.965, blue: 0.986, alpha: 1), NSColor(red: 0.105, green: 0.105, blue: 0.13, alpha: 1))
    static let selection = adaptive(NSColor(red: 0.895, green: 0.9, blue: 0.987, alpha: 1), NSColor(red: 0.24, green: 0.23, blue: 0.39, alpha: 1))
    static let line = Color.primary.opacity(0.10)
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// Color rule: linkColor marks interactive text only; icons and charts may use it as brand tint.
    /// Non-interactive text uses muted (info/progress), successText (completed) or tag chips.
    static let successText = adaptive(NSColor(red: 0.12, green: 0.50, blue: 0.22, alpha: 1), NSColor(red: 0.45, green: 0.85, blue: 0.52, alpha: 1))
    static let linkColor = adaptive(NSColor(red: 0.32, green: 0.30, blue: 0.94, alpha: 1), NSColor(red: 0.70, green: 0.67, blue: 1, alpha: 1))
    static let muted = adaptive(NSColor(red: 0.38, green: 0.38, blue: 0.42, alpha: 1), NSColor(red: 0.68, green: 0.68, blue: 0.73, alpha: 1))
    static let warningText = adaptive(NSColor(red: 0.57, green: 0.29, blue: 0.04, alpha: 1), NSColor(red: 0.96, green: 0.70, blue: 0.37, alpha: 1))
    static let errorText = adaptive(NSColor(red: 0.68, green: 0.15, blue: 0.13, alpha: 1), NSColor(red: 1, green: 0.54, blue: 0.51, alpha: 1))
}

/// Copied flag for CopyIconButton; the swiftc build has no SwiftUI macro plugin, so @State is unavailable.
@MainActor final class CopyFeedback: ObservableObject {
    @Published var copied = false
    private var token = 0
    func flash() {
        token += 1; let current = token
        // Respect "Reduce motion": switch the icon without animating.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(still ? nil : .easeOut(duration: 0.15)) { copied = true }
        // Only the latest click resets the icon, so rapid clicks keep the checkmark visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.token == current else { return }
            withAnimation(still ? nil : .easeIn(duration: 0.2)) { self.copied = false }
        }
    }
}

/// Copy icon that briefly turns into a checkmark after copying.
struct CopyIconButton: View {
    var help: String
    var action: () -> Void
    @StateObject private var feedback = CopyFeedback()
    @StateObject private var hover = HoverState()
    var body: some View {
        Button { action(); feedback.flash() } label: {
            Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc").frame(width: 28, height: 28)
                .foregroundStyle(feedback.copied ? Color.green : hover.active ? Color.primary : Theme.muted)
                .background(hover.active ? Theme.line.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle()).contentTransition(.symbolEffect(.replace))
        }
        .onHover { hover.active = $0 }
        .buttonStyle(.plain).help(L10n.text(feedback.copied ? "已复制" : help)).accessibilityLabel(L10n.text(feedback.copied ? "已复制" : "复制地址"))
    }
}

/// Shared metrics so primary and secondary buttons in the same row line up.
enum ButtonMetrics {
    static let height: CGFloat = 34
    static let padding: CGFloat = 16
    static let radius: CGFloat = 8
}

struct AccentButton: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View { FilledButtonBody(configuration: configuration, accent: true, destructive: destructive) }
}

/// Secondary action placed beside an AccentButton; same size, neutral fill.
struct SecondaryButton: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View { FilledButtonBody(configuration: configuration, accent: false, destructive: destructive) }
}

/// Shared body for AccentButton and SecondaryButton: one size, plus hover and pressed feedback.
private struct FilledButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let accent: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled
    @StateObject private var hover = HoverState()
    var body: some View {
        let active = enabled && hover.active
        let shape = RoundedRectangle(cornerRadius: ButtonMetrics.radius)
        configuration.label.font(.system(size: TypeScale.body, weight: accent ? .semibold : .medium))
            .foregroundStyle(accent ? Color.white : destructive ? Theme.errorText : Color.primary)
            .padding(.horizontal, ButtonMetrics.padding).frame(minHeight: ButtonMetrics.height)
            .background(fill(active: active), in: shape)
            .opacity(accent || enabled ? 1 : 0.45).contentShape(shape)
            .onHover { hover.active = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
    }
    private func fill(active: Bool) -> Color {
        if accent {
            let base = destructive ? Color.red : Theme.accent
            return base.opacity(!enabled ? 0.35 : configuration.isPressed ? 0.76 : active ? 0.88 : 1)
        }
        return Theme.line.opacity(configuration.isPressed ? 0.95 : active ? 0.8 : 0.6)
    }
}

struct PlainAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PlainActionBody(configuration: configuration) }
}
/// Link-style label; dims when disabled so it no longer reads as clickable.
private struct PlainActionBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label.foregroundStyle(enabled ? Theme.linkColor : Theme.muted).padding(.vertical, 8).frame(minHeight: 44)
            .opacity(!enabled ? 0.6 : configuration.isPressed ? 0.65 : 1)
    }
}

struct EngineIcon: View {
    var engine: Engine
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(engine.kind == .splash ? Theme.accent : engine.kind == .mlx ? Color(red: 0.16, green: 0.17, blue: 0.23) : Color.gray.opacity(0.68))
            if let path = engine.appPath, engine.kind == .llama {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().padding(size * 0.10)
            } else { Image(systemName: engine.symbol).font(.system(size: size * 0.49, weight: .medium)).foregroundStyle(.white) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct StateLabel: View {
    var title: String
    var color: Color = .gray
    var body: some View { HStack(spacing: 8) { Image(systemName: "circle.fill").font(.system(size: 10)).foregroundStyle(color); Text(verbatim: L10n.text(title)) }.font(.system(size: TypeScale.body)).accessibilityElement(children: .combine) }
}

extension ServiceStatus {
    var color: Color { switch self { case .running: return .green; case .starting, .stopping, .conflicted: return .orange; case .failed: return .red; case .stopped: return .gray } }
}

@MainActor
struct LanguageMenu: View {
    @ObservedObject var store: AppStore
    var compact: Bool
    private var shortName: String {
        switch store.language {
        case .english: return "EN"
        case .chinese: return "中"
        case .french: return "FR"
        case .portuguese: return "PT"
        case .system: return "Auto"
        }
    }
    var body: some View {
        Menu {
            Picker(L10n.text("界面语言"), selection: $store.language) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(verbatim: language.name).tag(language)
                }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 15))
                Text(verbatim: compact ? shortName : store.language.name).font(.system(size: compact ? TypeScale.caption : TypeScale.body, weight: .medium))
            }.frame(width: compact ? 44 : nil, height: 44)
        }
        .id(store.language)
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L10n.text("界面语言"))
        .accessibilityLabel(L10n.text("界面语言"))
        .accessibilityIdentifier("language-menu")
    }
}

/// Shared sidebar building blocks: every tab uses the same header, icon actions, section titles,
/// row chrome and spacing (title + trailing actions → optional filters → list → footer).
enum SidebarMetrics { static let padding: CGFloat = 20; static let spacing: CGFloat = 12 }

struct SidebarHeader<Actions: View>: View {
    var title: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 2) { Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.title, weight: .bold)).lineLimit(1); Spacer(minLength: 8); actions }
    }
}

struct SidebarIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.borderless).foregroundStyle(Theme.muted).help(L10n.text(help)).accessibilityLabel(L10n.text(help))
    }
}

struct SidebarSectionTitle: View {
    var title: String
    var body: some View { Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(Theme.muted) }
}

/// Square symbol tile used when a row has no engine icon.
struct SidebarSymbol: View {
    var symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.linkColor)
            .frame(width: 32, height: 32).background(Theme.linkColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Selection for the services sidebar, which mixes the gateway, managed services and discovered endpoints.
enum ServiceListSelection: Hashable { case gateway, managed(String), external(Int) }

extension View {
    /// Native sidebar list: arrow-key navigation, context menus and system selection, tinted with the app accent.
    /// The negative inset lines rows up with the sidebar header.
    func sidebarList() -> some View {
        // .inset draws a solid rounded selection (no sidebar vibrancy), which also renders in offscreen
        // documentation captures; rows hide separators so the list reads like a source list.
        listStyle(.inset).scrollContentBackground(.hidden).tint(Theme.accent).padding(.horizontal, -10)
    }
    /// Row chrome shared by all sidebar lists.
    func sidebarRow(selected: Bool) -> some View {
        padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }
}

/// Collapse/expand control placed at the trailing edge of each sidebar header (and on the collapsed rail).
@MainActor
struct SidebarToggleButton: View {
    @ObservedObject var store: AppStore
    var body: some View {
        let title = store.sidebarHidden ? "显示边栏" : "隐藏边栏"
        Button { store.toggleSidebar() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 30, height: 28).contentShape(Rectangle())
        }.buttonStyle(.borderless).foregroundStyle(Theme.muted)
            .help(L10n.text(title + " · ⌃⌘S")).accessibilityLabel(L10n.text(title)).accessibilityIdentifier("toggle-sidebar")
    }
}

/// Divider between sidebar and detail that can be dragged to resize the sidebar, like Finder or Xcode.
/// The hit area is wider than the 1 pt line; double-click restores the automatic width.
@MainActor
struct SidebarResizeHandle: View {
    @ObservedObject var store: AppStore
    var width: CGFloat
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if store.sidebarDragStart == nil { store.sidebarDragStart = width }
                            store.sidebarWidth = (store.sidebarDragStart ?? width) + value.translation.width
                        }
                        .onEnded { _ in store.sidebarDragStart = nil; store.saveSidebarWidth() })
                    .onTapGesture(count: 2) { store.sidebarWidth = nil; store.saveSidebarWidth() }
            }
            .accessibilityHidden(true)
    }
}

/// Collapsed sidebar: a slim rail that keeps the expand control where the collapse control was.
@MainActor
struct SidebarRail: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            VStack { SidebarToggleButton(store: store).padding(.top, 24); Spacer() }.frame(width: 44).frame(maxHeight: .infinity).background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 1)
        }
    }
}

/// Secondary explanation behind an ⓘ: shown on hover and read by VoiceOver, instead of a permanent paragraph.
struct InfoTip: View {
    var text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            .help(L10n.text(text)).accessibilityLabel(L10n.text(text))
    }
}

/// Run log in its own fixed-height scroll area, like a console. While following, new output scrolls
/// to the end; turning it off keeps the position so older lines can be read while the log updates.
struct LogView: View {
    var text: String
    var follow: Bool
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(verbatim: text).font(.system(size: TypeScale.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                    Color.clear.frame(height: 1).id("log-end")
                }
            }
            .frame(height: 380).background(Theme.line.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
            .onAppear { proxy.scrollTo("log-end", anchor: .bottom) }
            .onChange(of: text) { _, _ in if follow { proxy.scrollTo("log-end", anchor: .bottom) } }
            .onChange(of: follow) { _, on in if on { proxy.scrollTo("log-end", anchor: .bottom) } }
        }
    }
}

/// Last scan time with an inline rescan control, shown under the engine and model lists that a scan refreshes.
@MainActor
struct ScanStatus: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 6) {
            if store.scanning {
                ProgressView().controlSize(.mini)
                Text(verbatim: L10n.text("正在扫描模型文件…"))
            } else if let date = store.inventory?.scannedAt {
                Text(verbatim: L10n.text("更新于 \(date.formatted(date: .omitted, time: .shortened))"))
            }
            Button { store.scan() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).disabled(store.scanning)
                .help(L10n.text("重新扫描模型与引擎 · ⌘R")).accessibilityLabel(L10n.text("重新扫描")).accessibilityIdentifier("rescan")
        }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
    }
}

@MainActor
struct MainView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack {
                    let tabWidth = min(146, (geometry.size.width - 300) / CGFloat(AppTab.allCases.count))
                    HStack(spacing: 0) {
                        ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                            Button { store.tab = tab } label: { Text(verbatim: L10n.text(tab.rawValue)).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).frame(width: tabWidth, height: 44).background(store.tab == tab ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(store.tab == tab ? Color.white : Color.primary).contentShape(RoundedRectangle(cornerRadius: 11)) }
                                .buttonStyle(.plain).keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command).accessibilityIdentifier("tab-\(index)")
                        }
                    }.padding(3).background(Theme.line.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    // Rescan lives beside the lists it refreshes (ScanStatus) and in File ▸ Rescan (⌘R).
                    HStack(spacing: 6) { Spacer(); LanguageMenu(store: store, compact: geometry.size.width < 1200) }.padding(.trailing, 20)
                }.frame(height: 64)
                Rectangle().fill(Theme.line).frame(height: 1)
                // User-dragged width wins (clamped to 260 pt … half the window); otherwise scale with the window.
                let sidebarWidth = store.sidebarWidth.map { min(max($0, 260), max(260, geometry.size.width * 0.5)) } ?? max(310, min(420, geometry.size.width * 0.292))
                switch store.tab {
                case .engines: EngineWorkspace(store: store, services: services, sidebarWidth: sidebarWidth)
                case .models: ModelWorkspace(store: store, sidebarWidth: sidebarWidth)
                case .services: ServiceWorkspace(store: store, services: services, sidebarWidth: sidebarWidth)
                case .downloads: DownloadWorkspace(store: store, downloads: store.downloads, sidebarWidth: sidebarWidth)
                case .monitor: MonitorWorkspace(store: store, services: services, monitor: store.resources, performance: store.performance)
                case .solutions: SolutionWorkspace(store: store, controller: store.solutions, sidebarWidth: sidebarWidth)
                }
            }.background(Theme.background)
        // Child views translate inside their own body; an unchanged input (e.g. StateLabel("未启动")) would keep
        // the previous language, so rebuild the tree when the language changes.
        }.frame(minWidth: 980, minHeight: 700).ignoresSafeArea().environment(\.locale, L10n.locale).id(store.language)
            .alert(L10n.text("删除端口 \(store.serviceRemoval?.port ?? 0) 的服务配置"), isPresented: Binding(get: { store.serviceRemoval != nil }, set: { if !$0 { store.serviceRemoval = nil } })) {
                Button(L10n.text("删除"), role: .destructive) { if let spec = store.serviceRemoval { store.removeServiceConfiguration(spec) }; store.serviceRemoval = nil }
                Button(L10n.text("取消"), role: .cancel) { store.serviceRemoval = nil }
            } message: { Text(verbatim: store.serviceRemoval.map(store.serviceRemovalMessage) ?? "") }
            .alert(L10n.text("模型管理"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button(L10n.text("好")) { store.message = nil } } message: { Text(verbatim: L10n.text(store.message ?? "")) }
            .sheet(item: $store.maintenancePlan) { plan in MaintenanceView(store: store, plan: plan) }
            .sheet(isPresented: $store.showLaunch) { LaunchSheet(store: store, services: services) }
            .sheet(item: Binding(get: { store.installation.plan }, set: { store.installation.plan = $0 })) { plan in EngineInstallView(store: store, installer: store.installation, plan: plan) }
            .sheet(item: $store.multiModel) { draft in MultiModelView(store: store, draft: draft) }
            .sheet(item: $store.commandDraft) { draft in CommandLaunchView(store: store, draft: draft) }
            .sheet(item: $store.modelUpdate) { draft in ModelUpdateView(store: store, draft: draft) }
            .sheet(item: $store.engineConfigurationDraft) { draft in EngineConfigurationView(store: store, draft: draft) }
            .sheet(item: $store.associationDraft) { draft in ModelAssociationView(store: store, draft: draft) }
            .sheet(item: $store.chat) { session in ChatPlaygroundView(store: store, session: session) }
            .sheet(item: $store.solutionExperience) { session in SolutionExperienceView(store: store, session: session) }
            .sheet(item: $store.instanceBenchmark) { draft in InstanceBenchmarkView(store: store, performance: store.performance, draft: draft) }
            .sheet(isPresented: $store.showGlobalEngines) { GlobalEngineSettingsView(store: store) }
            .sheet(item: Binding(get: { store.connections.draft }, set: { store.connections.draft = $0 })) { draft in ClientConnectionsView(store: store, controller: store.connections, port: draft.port) }
            .sheet(item: Binding(get: { store.gateway.editor }, set: { store.gateway.editor = $0 })) { draft in GatewayEndpointView(store: store, gateway: store.gateway, draft: draft) }
    }
}

@MainActor
struct EngineWorkspace: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var sidebarWidth: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarHidden {
            VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
                SidebarHeader(title: "运行引擎") {
                    SidebarIconButton(symbol: "slider.horizontal.3", help: "全局引擎设置") { store.showGlobalEngines = true }.accessibilityIdentifier("global-engine-settings")
                    SidebarToggleButton(store: store)
                }.padding(.bottom, 4)
                List(selection: Binding(get: { store.engineID as String? }, set: { if let id = $0, id != store.engineID { store.chooseEngine(id) } })) {
                    ForEach(store.enabledEngines) { engine in
                        engineRow(engine).padding(.vertical, 4).tag(engine.id).listRowSeparator(.hidden)
                            .help(L10n.text(engine.path)).accessibilityIdentifier("engine-\(engine.id)")
                            .contextMenu {
                                Button(L10n.text("在 Finder 中打开")) { store.reveal(engine.path) }.disabled(!store.canReveal(engine.path))
                                Button(L10n.text("全局引擎设置")) { store.showGlobalEngines = true }
                            }
                    }
                }.sidebarList()
                Spacer(minLength: 0)
                ScanStatus(store: store)
            }.padding(SidebarMetrics.padding).frame(width: sidebarWidth, alignment: .leading).clipped().background(Theme.sidebar)
            SidebarResizeHandle(store: store, width: sidebarWidth)
            } else { SidebarRail(store: store) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.enabledEngines.isEmpty {
                        EmptyMessage(symbol: "slider.horizontal.3", title: L10n.text("所有引擎已禁用"), detail: "打开全局引擎设置，启用需要使用的基座。")
                        Button(L10n.text("全局引擎设置")) { store.showGlobalEngines = true }.buttonStyle(.bordered)
                    } else {
                    HStack(spacing: 18) { EngineIcon(engine: store.engine, size: 64); VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(store.engine.name)).font(.system(size: TypeScale.display, weight: .bold)); Text(verbatim: L10n.text(store.engine.description)).font(.system(size: TypeScale.section)).foregroundStyle(Theme.muted) }; Spacer() }.padding(.vertical, 8)
                    Picker(L10n.text("运行引擎"), selection: $store.engineSection) { ForEach(EngineSection.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 16).padding(.bottom, 20).accessibilityIdentifier("engine-sections")
                    switch store.engineSection {
                    case .overview:
                    EngineInstallPanel(store: store, installer: store.installation)
                    Text(verbatim: L10n.text("引擎信息")).font(.system(size: TypeScale.section, weight: .semibold)).padding(.top, 28).padding(.bottom, 20)
                    HStack(spacing: 16) {
                        InfoCell(symbol: "gearshape", title: L10n.text("版本"), value: store.engine.version)
                        Divider().frame(height: 48)
                        InfoCell(symbol: "laptopcomputer", title: L10n.text("运行设备"), value: store.inventory?.chip ?? "本机 Mac")
                        Divider().frame(height: 48)
                        InfoCell(symbol: "memorychip", title: L10n.text("系统内存"), value: "\((store.inventory?.memoryBytes ?? 0) / 1_073_741_824) GB")
                    }.padding(.bottom, 24)
                    HStack(spacing: 18) { Image(systemName: "internaldrive").font(.system(size: 30)).foregroundStyle(Theme.muted); VStack(alignment: .leading, spacing: 7) { Text(verbatim: L10n.text("模型与缓存")).foregroundStyle(Theme.muted).font(.system(size: TypeScale.body)); Text(verbatim: L10n.text(sizeLabel(store.inventory?.storageBytes ?? 0))).font(.system(size: TypeScale.body)) }; Spacer(); if let app = store.engine.appPath { Button(L10n.text("打开应用")) { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }.buttonStyle(PlainAction()) } }.padding(.top, 20).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    Button { store.reveal(store.engine.path) } label: { Label(L10n.text("查看引擎安装位置"), systemImage: "folder") }.buttonStyle(PlainAction()).disabled(!store.canReveal(store.engine.path)).font(.system(size: TypeScale.body)).padding(.top, 16)
                    case .services:
                    EngineServicesView(store: store, services: services)
                    HStack {
                        Button { store.showLaunch = true } label: { Label(L10n.text("启动服务…"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(!store.engine.canServe).accessibilityIdentifier("open-launch")
                        Button { store.prepareCommand() } label: { Label(L10n.text("按命令行启动…"), systemImage: "terminal") }.buttonStyle(SecondaryButton()).disabled(!store.engine.canServe || store.installation.running || store.maintaining).accessibilityIdentifier("command-launch-entry")
                        Spacer()
                        if let model = store.selectedModel { Button(L10n.text("检查模型更新…")) { store.prepareModelUpdate(model) }.buttonStyle(SecondaryButton()) }
                    }.padding(.top, 16)
                    case .configuration:
                    if store.engine.kind == .splash { SplashRecommendationsView(store: store).padding(.bottom, 24) }
                    HStack { Text(verbatim: L10n.text("兼容的本地模型")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer(); Button { store.showEngineModels(store.engineID) } label: { Label(L10n.text("管理模型文件"), systemImage: "folder") }.buttonStyle(PlainAction()).font(.system(size: TypeScale.body)) }.padding(.bottom, 22)
                    HStack(spacing: 6) { Text(verbatim: L10n.text(store.engine.modelRule)).font(.system(size: TypeScale.body, weight: .medium)); InfoTip(text: store.engine.modalityGuide.summary) }.padding(.bottom, 14)
                    HStack { Button(L10n.text("引擎配置…")) { store.prepareEngineConfiguration() }.buttonStyle(.bordered).accessibilityIdentifier("engine-configuration"); if !store.engineEnabled(store.engineID) { Text(verbatim: L10n.text("此基座已停用")).foregroundStyle(Theme.warningText) } }.padding(.bottom, 14)
                    if store.engine.kind == .strata { StrataIntegrationView(store: store).padding(.bottom, 18) }
                    if store.engine.kind == .mflux { ImageEngineSetupView(store: store).padding(.bottom, 18) }
                    if let model = store.selectedModel { UsageBadge(model: model).padding(.bottom, 12) }
                    if store.scanning && store.inventory == nil { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text("正在扫描模型文件…")).foregroundStyle(Theme.muted) }.frame(height: 84) }
                    else if store.compatibleModels.isEmpty { EmptyMessage(symbol: "cube", title: store.engine.kind == .ollama ? "还没有 Ollama 格式的模型" : "没有兼容的本地模型", detail: store.engine.kind == .ollama ? "可以先启动 Ollama 模型管理服务。" : "在“模型文件”中添加模型目录，或选择其他引擎。") }
                    else {
                        VStack(spacing: 10) { ForEach(store.compatibleModels) { model in
                            EngineModelCard(store: store, model: model)
                        } }
                    }
                    case .maintenance:
                    HStack(spacing: 18) {
                        Button { store.prepareMaintenance(.uninstall) } label: { Label(L10n.text("卸载引擎…"), systemImage: "trash") }.buttonStyle(.bordered).tint(.red)
                        Button { store.prepareMaintenance(.residues) } label: { Label(L10n.text("清理残留…"), systemImage: "sparkles") }.buttonStyle(.bordered)
                        InfoTip(text: "先预览安装包、残留和关联模型。专属权重可单独勾选，共享目录保留。")
                        if store.preparingMaintenance { ProgressView().controlSize(.small) }
                    }.disabled(store.preparingMaintenance || store.maintaining || store.scanning || store.installation.running)
                    if let warnings = store.inventory?.warnings, !warnings.isEmpty { Text(verbatim: L10n.text(warnings.joined(separator: "\n"))).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText).padding(.top, 12) }
                    }
                    }
                }.padding(30)
            }.id(store.engineID + store.engineSection.rawValue + (store.engineInstanceFilter?.model.id ?? "")).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder func engineRow(_ engine: Engine) -> some View {
        let status = engine.installed ? "已安装" : engine.installation == "仅残留组件" ? "仅残留组件" : "未安装"
        let services = store.engineServiceCount(engine.id)
        // Single column: a fixed-width status column used to wrap names and truncate the model rule.
        HStack(alignment: .top, spacing: 10) {
            EngineIcon(engine: engine, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.text(engine.name)).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(engine.installed ? Color.green : Color.gray)
                    Text(verbatim: L10n.text(status))
                    // Uninstalled engines report a "—" placeholder version; hide it instead of showing noise.
                    if engine.version != "—", !engine.version.isEmpty { Text(verbatim: "· " + L10n.text(EngineVersionPolicy.displayVersion(engine))) }
                }.font(.system(size: TypeScale.callout)).foregroundStyle(.secondary).lineLimit(1)
                let detail = services > 0 ? "\(services) 个服务实例" : engine.installation
                if detail != status { Text(verbatim: L10n.text(detail)).font(.system(size: TypeScale.caption)).foregroundStyle(.secondary).lineLimit(1) }
                Text(verbatim: L10n.text(engine.modelRule)).font(.system(size: TypeScale.caption)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct LaunchPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var supportsContext: Bool { [EngineKind.splash, .llama, .prism, .ollama].contains(store.engine.kind) || (store.engine.kind == .mlx && store.engine.visionPath != nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.engine.kind == .splash, let model = store.selectedModel, model.preparedForSplash() == nil, let reason = SplashRuntime.packedReason(store.engine) {
                Label(L10n.text(model.format.hasPrefix("Splash") ? reason : model.compatibility(with: store.engine).reason), systemImage: "info.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.warningText)
            }
            if store.inputMode == .multimodal, let reason = store.nativeInputReason {
                Label(L10n.text("无法按多模态启动：" + reason), systemImage: "exclamationmark.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.warningText)
                Button(L10n.text("改为纯文本启动")) { store.inputMode = .text }.buttonStyle(.bordered)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 24) { portField; endpointField; actionGroup }
                VStack(alignment: .leading, spacing: 18) { HStack(spacing: 20) { portField; endpointField }; actionGroup }
            }
            HStack {
                if let model = store.selectedModel { Button { store.reveal(model.path) } label: { Label(L10n.text("在 Finder 中打开"), systemImage: "folder") }.buttonStyle(PlainAction()) }
                if let model = store.selectedModel, model.kind == .language { Button(L10n.text("配套组件…")) { store.prepareAssociation(model) }.buttonStyle(.bordered) }
                Spacer()
                if supportsContext { Button { store.advanced.toggle() } label: { Label(L10n.text("更多设置"), systemImage: store.advanced ? "chevron.up" : "chevron.down").font(.system(size: TypeScale.body)) }.buttonStyle(PlainAction()) }
            }
            InputModeView(store: store)
            if [EngineKind.llama, .prism, .mlx, .splash].contains(store.engine.kind) { MemoryEstimateView(store: store, model: store.selectedModel, context: store.context) }
            if store.advanced && supportsContext { HStack { Text(verbatim: L10n.text("上下文长度")).foregroundStyle(Theme.muted); Picker(L10n.text("上下文长度"), selection: $store.context) { ForEach([2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144], id: \.self) { Text(verbatim: L10n.text("\($0) tokens")).tag($0) } }.labelsHidden().frame(width: 170); Spacer() }.font(.system(size: TypeScale.body)) }
            if store.advanced && store.engine.kind == .ollama { HStack { Text(verbatim: L10n.text("最大常驻模型")).foregroundStyle(Theme.muted); Picker(L10n.text("最大常驻模型"), selection: $store.maximumLoadedModels) { ForEach(1...8, id: \.self) { Text(verbatim: L10n.text("\($0) 个")).tag($0) } }.labelsHidden().frame(width: 170); Spacer() }.font(.system(size: TypeScale.body)); Text(verbatim: L10n.text("启动此服务时生效；实际加载数量仍取决于可用内存。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            HStack {
                Label(L10n.text(store.engine.multiModelDescription), systemImage: "square.stack.3d.up").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                Spacer(minLength: 12)
                Button { store.prepareMultiModel() } label: { Text(verbatim: L10n.text(store.engine.independentModels ? "启动多个模型…" : "加载多个模型…")) }.buttonStyle(.bordered).disabled(store.preparingMulti || store.installation.activeEngineID == store.engineID || (store.maintaining && store.maintenanceEngineID == store.engineID) || (store.engine.independentModels && !store.engine.canServe) || (store.engine.kind == .lmstudio && !store.engine.installed))
                if store.preparingMulti { ProgressView().controlSize(.small) }
            }
            if store.parsedPort == nil { Text(verbatim: L10n.text("端口需要在 1024–65535 之间")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText) }
            if !store.engine.canServe { Text(verbatim: L10n.text(store.engine.kind == .mlx ? "推理库已安装，尚未发现可直接启动的 MLX-LM 服务程序。" : "当前仅能查看组件；需要对应应用提供服务。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
            if let conflict = store.portConflict {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.text(conflict), systemImage: "exclamationmark.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.warningText)
                    HStack(spacing: 18) {
                        Button(L10n.text("使用空闲端口")) { store.useFreePort() }.buttonStyle(.bordered).disabled(store.currentService?.pid != nil).accessibilityIdentifier("choose-free-port")
                        Button(L10n.text("查看占用服务")) { store.showPortOwner() }.buttonStyle(PlainAction())
                    }
                }
            }
            if let id = store.currentService?.id, let error = services.errors[id] { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText); Button(L10n.text("查看运行日志")) { store.selectedServiceID = id; store.tab = .services }.buttonStyle(PlainAction()) }
        }.padding(24).background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 13)).overlay { RoundedRectangle(cornerRadius: 13).stroke(Theme.line, lineWidth: 1) }
    }
    var portField: some View { VStack(alignment: .leading, spacing: 10) { Text(verbatim: L10n.text("服务端口")).font(.system(size: TypeScale.body)); TextField(L10n.text("8000"), text: $store.port).textFieldStyle(.plain).font(.system(size: TypeScale.section)).padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.line) }.accessibilityIdentifier("service-port") }.frame(width: 136) }
    var endpointField: some View { VStack(alignment: .leading, spacing: 10) { Text(verbatim: L10n.text("本地接口地址")).font(.system(size: TypeScale.body)); HStack(spacing: 6) { Text(verbatim: L10n.text("127.0.0.1:\(store.port)/v1")).font(.system(size: TypeScale.body, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8); Spacer(minLength: 0); Button { store.copy("http://127.0.0.1:\(store.port)/v1") } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }.buttonStyle(.plain).help(L10n.text("复制完整接口地址")) }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48).background(Theme.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 8)) }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading) }
    var actionGroup: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) { Text(verbatim: L10n.text("服务状态")).font(.system(size: TypeScale.body)); StateLabel(title: store.portConflict != nil ? "端口已占用" : store.currentStatus.title, color: store.portConflict != nil ? .orange : store.currentStatus.color).frame(height: 48) }
            if let spec = store.currentService, spec.pid != nil { Button { store.stop(spec) } label: { Label(L10n.text("停止服务"), systemImage: "stop.fill") }.buttonStyle(AccentButton(destructive: true)).disabled(store.currentStatus == .stopping) }
            else { Button { store.start() } label: { Label(L10n.text("启动服务"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(!store.canStart).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("start-service") }
        }
    }
}

struct InfoCell: View {
    var symbol: String; var title: String; var value: String
    var body: some View { HStack(spacing: 15) { Image(systemName: symbol).font(.system(size: 31, weight: .light)); VStack(alignment: .leading, spacing: 10) { Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); Text(verbatim: L10n.text(value)).font(.system(size: TypeScale.body)).lineLimit(1).minimumScaleFactor(0.8) } }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct EmptyMessage: View {
    var symbol: String; var title: String; var detail: String
    var body: some View { VStack(alignment: .leading, spacing: 14) { Label(L10n.text(title), systemImage: symbol).font(.system(size: TypeScale.body, weight: .medium)); Text(verbatim: L10n.text(detail)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)) }
}

@MainActor
struct ModelWorkspace: View {
    @ObservedObject var store: AppStore
    var sidebarWidth: CGFloat
    var categoryPicker: some View {
        Picker(L10n.text("模型分类"), selection: $store.modelFilter) { ForEach(["全部", "主模型", "附属模型"], id: \.self) { Text(verbatim: L10n.text($0)) } }.labelsHidden()
    }
    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarHidden {
            VStack(alignment: .leading, spacing: 12) {
                SidebarHeader(title: "模型文件") {
                    SidebarIconButton(symbol: "plus", help: "导入本地模型文件或目录") { store.importLocalModels() }
                    SidebarToggleButton(store: store)
                }.padding(.bottom, 4)
                TextField(L10n.text("搜索名称、格式或路径"), text: $store.search).textFieldStyle(.roundedBorder).font(.system(size: TypeScale.body)).accessibilityIdentifier("model-search").onChange(of: store.search) { _, _ in selectVisibleModel() }
                Picker(L10n.text("模型基座"), selection: $store.modelEngineFilter) { Text(verbatim: L10n.text("全部基座")).tag(""); ForEach(store.enabledEngines) { Text(verbatim: L10n.text($0.name)).tag($0.id) } }.labelsHidden().fixedSize().frame(maxWidth: .infinity, alignment: .leading).onChange(of: store.modelEngineFilter) { _, _ in selectVisibleModel() }
                // Segmented when it fits; long translations in a narrow sidebar fall back to a menu instead of
                // forcing the column wider than the sidebar (which clipped the whole sidebar).
                ViewThatFits(in: .horizontal) {
                    categoryPicker.pickerStyle(.segmented).fixedSize()
                    categoryPicker.pickerStyle(.menu).fixedSize()
                }.frame(maxWidth: .infinity, alignment: .leading).onChange(of: store.modelFilter) { _, _ in selectVisibleModel() }.padding(.bottom, 4)
                List(selection: $store.selectedFileID) {
                    ForEach(store.filteredModels) { model in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: model.kind == .image ? "photo.badge.plus" : model.kind == .speech ? "waveform" : model.kind == .adapter ? "slider.horizontal.3" : model.kind == .embedding ? "text.magnifyingglass" : "cube").font(.system(size: 14)).foregroundStyle(Theme.linkColor)
                                .frame(width: 28, height: 28).background(Theme.linkColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.name).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                // Completeness: dot plus text when incomplete, so color is not the only signal.
                                HStack(spacing: 6) {
                                    Circle().fill(model.complete ? Color.green : Color.orange).frame(width: 6, height: 6)
                                    Text(verbatim: L10n.text("\(model.format) · \(sizeLabel(model.bytes))")).lineLimit(1)
                                    if !model.complete { Text(verbatim: L10n.text("文件不完整")).foregroundStyle(Theme.warningText) }
                                }.font(.system(size: TypeScale.callout)).foregroundStyle(.secondary)
                                    .accessibilityElement(children: .combine).accessibilityLabel(L10n.text("\(model.format) · \(sizeLabel(model.bytes)) · " + (model.complete ? "文件检查通过" : "文件不完整")))
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) { UsageBadge(model: model); ModelCapabilityBadge(capabilities: store.modelCapabilities(model), compact: true) }
                                    VStack(alignment: .leading, spacing: 4) { UsageBadge(model: model); ModelCapabilityBadge(capabilities: store.modelCapabilities(model), compact: true) }
                                }
                                if model.kind == .language || model.kind == .image || model.kind == .embedding || AudioModelPolicy.task(model) != nil || store.modelInstanceCounts(model).total > 0 { ModelInstancesLink(store: store, model: model, compact: true) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 4).tag(Optional(model.id)).listRowSeparator(.hidden).help(L10n.text(model.path))
                        .contextMenu {
                            Button(L10n.text("在 Finder 中打开")) { store.reveal(model.path) }
                            Button(L10n.text("删除模型…"), role: .destructive) { store.deleteModel(model) }
                        }
                    }
                }.sidebarList()
                // ⌫ goes through deleteModel, which always asks first (Cancel is the default button).
                .onDeleteCommand { if let model = store.selectedFile { store.deleteModel(model) } }
                HStack { Text(verbatim: L10n.text("\(store.filteredModels.count) 个模型条目")); Spacer(); Text(verbatim: L10n.text("目录总占用 " + sizeLabel(store.inventory?.storageBytes ?? 0))) }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                ScanStatus(store: store)
            }.padding(20).frame(width: sidebarWidth, alignment: .leading).clipped().background(Theme.sidebar)
            SidebarResizeHandle(store: store, width: sidebarWidth)
            } else { SidebarRail(store: store) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let model = store.selectedFile {
                        Text(model.name).font(.system(size: TypeScale.title, weight: .bold)).textSelection(.enabled)
                        Text(verbatim: L10n.text("\(model.format) · \(sizeLabel(model.bytes))")).font(.system(size: TypeScale.section)).foregroundStyle(Theme.muted)
                        ModelCapabilityBadge(capabilities: store.modelCapabilities(model), prefix: "模型输入 · ")
                        Text(verbatim: L10n.text(store.modelCapabilities(model).source)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                        StateLabel(title: model.verification, color: model.complete ? .green : .orange)
                        if model.kind == .language || model.kind == .image || model.kind == .embedding || AudioModelPolicy.task(model) != nil || store.modelInstanceCounts(model).total > 0 { ModelInstancesLink(store: store, model: model) }
                        Divider()
                        if model.kind == .draft { DraftModelInfo(store: store, model: model) }
                        else {
                            Text(verbatim: L10n.text("启动模型")).font(.system(size: TypeScale.section, weight: .semibold))
                            CompatibilityRows(store: store, model: model)
                            ModelLocalVersions(store: store, model: model)
                            if model.kind == .language { ModelAssociationEntry(store: store, model: model) }
                            PreparedEngineComponentsView(store: store, model: model)
                        }
                        Divider()
                        ModelUpdateEntry(store: store, model: model)
                        Divider()
                        Text(verbatim: L10n.text("文件位置")).font(.system(size: TypeScale.section, weight: .semibold))
                        Text(model.path).font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled).lineSpacing(5).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 22) { Button { store.reveal(model.path) } label: { Label(L10n.text("在 Finder 中打开"), systemImage: "folder") }.buttonStyle(PlainAction()); Button { store.copy(model.path) } label: { Label(L10n.text("复制路径"), systemImage: "doc.on.doc") }.buttonStyle(PlainAction()); Spacer(); Button(role: .destructive) { store.deleteModel(model) } label: { Label(L10n.text(model.format == "Ollama" ? "删除模型…" : "移至废纸篓…"), systemImage: "trash") }.buttonStyle(.bordered).disabled(store.modelFiles.deletingID != nil).accessibilityIdentifier("delete-model") }
                        Divider()
                        ModelFileListView(store: store, files: store.modelFiles, model: model)
                        Divider()
                        Text(verbatim: L10n.text("适配基座")).font(.system(size: TypeScale.section, weight: .semibold))
                        CompatibilityRows(store: store, model: model)
                        if model.kind == .language { Divider(); ModelPerformanceSummary(store: store, performance: store.performance, model: model) }
                        if !model.missingFiles.isEmpty { Text(verbatim: L10n.text("缺失文件")).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(model.missingFiles.joined(separator: "\n"))).font(.system(size: TypeScale.body, design: .monospaced)).foregroundStyle(Theme.warningText) }
                        Divider()
                        Text(verbatim: L10n.text(model.pathExtensionDescription)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    } else { EmptyMessage(symbol: "folder", title: L10n.text("选择一个模型"), detail: "添加模型目录后，可以查看文件、完整性和兼容引擎。") }
                }.padding(34)
            }.frame(maxWidth: .infinity)
        }
    }
    func selectVisibleModel() { if !store.filteredModels.contains(where: { $0.id == store.selectedFileID }) { store.selectedFileID = store.filteredModels.first?.id } }
}

extension LocalModel {
    var pathExtensionDescription: String { format == "Ollama" ? "Ollama 删除需确认对应服务和模型目录；共享层由引擎处理，恢复需重新下载或导入。" : format.hasPrefix("GGUF") ? "移至废纸篓仅处理所选权重文件；共享的视觉投影文件会保留。" : "模型可从废纸篓恢复；同一目录中的其他模型会保留。" }
}

@MainActor
struct ServiceWorkspace: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var sidebarWidth: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarHidden {
            VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
                SidebarHeader(title: "模型服务") {
                    SidebarIconButton(symbol: "plus", help: "启动服务…") { store.showLaunch = true }.accessibilityIdentifier("new-service")
                    SidebarToggleButton(store: store)
                }.padding(.bottom, 4)
                Picker(L10n.text("模型基座"), selection: $store.serviceEngineFilter) { Text(verbatim: L10n.text("全部基座")).tag(""); ForEach(store.engines) { Text(verbatim: L10n.text($0.name)).tag($0.id) } }.labelsHidden().fixedSize().frame(maxWidth: .infinity, alignment: .leading).onChange(of: store.serviceEngineFilter) { _, _ in store.selectVisibleService() }
                Picker(L10n.text("服务状态"), selection: $store.serviceStateFilter) {
                    ForEach(ServiceStateFilter.allCases, id: \.self) { filter in Text(verbatim: L10n.text(filter.title)).tag(filter) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .accessibilityLabel(L10n.text("服务状态")).accessibilityIdentifier("service-state-filter")
                List(selection: Binding(get: { serviceSelection }, set: { selectService($0) })) {
                    HStack(spacing: 10) { SidebarSymbol(symbol: "point.3.connected.trianglepath.dotted"); VStack(alignment: .leading, spacing: 3) { Text(verbatim: L10n.text("统一网关")).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(store.gateway.ready ? "运行中 · \(store.gateway.routes.filter(\.enabled).count) 个模型" : "本机与外部接口统一接入")).font(.system(size: TypeScale.callout)).foregroundStyle(.secondary) }; Spacer(minLength: 0) }.padding(.vertical, 4).tag(ServiceListSelection.gateway).listRowSeparator(.hidden).accessibilityIdentifier("show-gateway")
                    Section { 
                        if store.visibleServices.isEmpty { Text(verbatim: L10n.text(store.hasServiceFilters ? "没有符合筛选条件的受管服务" : "此范围还没有配置服务")).font(.system(size: TypeScale.callout)).foregroundStyle(.secondary).listRowSeparator(.hidden) }
                        ForEach(store.visibleServices) { spec in
                            serviceRow(title: store.engines.first { $0.id == spec.engineID }?.name ?? spec.engineID, detail: "\(store.serviceDisplayName(spec)) · \(spec.port)", status: services.statusTitle(spec), color: services.status(spec).color, engine: store.engines.first { $0.id == spec.engineID }, origin: store.serviceOrigin(spec))
                                .tag(ServiceListSelection.managed(spec.id)).listRowSeparator(.hidden)
                                .contextMenu {
                                    Button(L10n.text("复制接口地址")) { store.copy("http://127.0.0.1:\(spec.port)/v1") }
                                    Button(L10n.text("删除服务配置…"), role: .destructive) { store.serviceRemoval = spec }.disabled(!services.canRemoveConfiguration(spec))
                                }
                        }
                    } header: { SidebarSectionTitle(title: "由 ModelDock 管理") }
                    if store.serviceStateFilter != .stopped { Section {
                        if store.visibleExternalServices.isEmpty { Text(verbatim: L10n.text("未发现此范围的本地接口")).font(.system(size: TypeScale.callout)).foregroundStyle(.secondary).listRowSeparator(.hidden) }
                        ForEach(store.visibleExternalServices) { item in
                            serviceRow(title: item.engineName, detail: "127.0.0.1:\(item.port)", status: item.ready ? "接口可用" : "端口已占用", color: item.ready ? .green : .orange)
                                .tag(ServiceListSelection.external(item.port)).listRowSeparator(.hidden)
                        }
                    } header: { SidebarSectionTitle(title: "本机已发现") } }
                }.sidebarList()
                .onChange(of: store.visibleServices.map(\.id)) { _, _ in store.selectVisibleService() }
                .onChange(of: store.visibleExternalServices.map(\.port)) { _, _ in store.selectVisibleService() }
                // ⌫ only asks to delete a managed configuration; the confirmation alert does the rest.
                .onDeleteCommand { if case .managed(let id) = serviceSelection, let spec = services.records.first(where: { $0.id == id }), services.canRemoveConfiguration(spec) { store.serviceRemoval = spec } }
                Text(verbatim: L10n.text("每 3 秒检查本机常用模型端口")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }.padding(SidebarMetrics.padding).frame(width: sidebarWidth, alignment: .leading).clipped().background(Theme.sidebar)
            SidebarResizeHandle(store: store, width: sidebarWidth)
            } else { SidebarRail(store: store) }
            ScrollView {
                if store.gatewaySelected { GatewayWorkspace(store: store, gateway: store.gateway) }
                else {
                VStack(alignment: .leading, spacing: 24) {
                    if let port = store.selectedExternal, let external = store.visibleExternalServices.first(where: { $0.port == port }) {
                        Text(verbatim: L10n.text(external.engineName)).font(.system(size: TypeScale.display, weight: .bold)); StateLabel(title: external.ready ? "接口可用 · 外部启动" : "端口已占用 · 外部启动", color: external.ready ? .green : .orange)
                        HStack(spacing: 8) {
                            Text(verbatim: "http://127.0.0.1:\(port)/v1").font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled)
                            CopyIconButton(help: "复制完整接口地址") { store.copy("http://127.0.0.1:\(port)/v1") }
                        }
                        if let pid = external.pid { Text(verbatim: L10n.text("监听进程 · PID \(pid)")).font(.system(size: TypeScale.body, design: .monospaced)).foregroundStyle(Theme.muted) }
                        Text(verbatim: L10n.text(external.engineID == nil ? "尚未识别引擎；端口和模型名称不能确认引擎类型。" : "引擎已根据监听进程识别。"))
                            .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                        HStack(spacing: 10) {
                            if external.ready && store.directConnectionTargets.contains(where: { $0.port == port }) { Button { store.openChat(port: port) } label: { Label(L10n.text("试聊"), systemImage: "bubble.left.and.bubble.right") }.buttonStyle(SecondaryButton()) }
                            Button(L10n.text("打开服务页面")) { store.openEndpoint(port) }.buttonStyle(SecondaryButton())
                        }
                        ConnectionEntry(store: store, port: port)
                        InstancePerformanceEntry(store: store, performance: store.performance, port: port)
                        Divider(); Text(verbatim: L10n.text("服务报告的模型")).font(.system(size: TypeScale.section, weight: .semibold))
                        ForEach(external.models, id: \.self) { name in VStack(alignment: .leading, spacing: 8) { Text(name).font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled); ModelCapabilityBadge(capabilities: services.modelCapabilities[port]?[name] ?? ModelCapabilities(), prefix: "当前服务 · ") } }
                        if external.engineID == "ollama" { OllamaLoadedView(store: store, services: services, port: port) }
                        if external.models.isEmpty { Text(verbatim: L10n.text(external.statusCode.map { "接口返回 HTTP \($0)，暂时没有模型列表。" } ?? "这个端口暂未响应模型接口。")).foregroundStyle(Theme.muted) }
                        Text(verbatim: L10n.text("外部服务通过原应用停止；本工具不会停止无法确认归属的进程。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                    } else if let spec = store.visibleServices.first(where: { $0.id == store.selectedServiceID }) ?? store.visibleServices.first {
                        let status = services.status(spec)
                        Text(verbatim: L10n.text(store.engines.first { $0.id == spec.engineID }?.name ?? spec.engineID)).font(.system(size: TypeScale.display, weight: .bold))
                        Text(verbatim: store.serviceDisplayName(spec)).font(.system(size: TypeScale.section)).foregroundStyle(Theme.muted)
                        if let names = services.reportedModels[spec.port], !names.isEmpty {
                            Text(verbatim: L10n.text("API 模型 ID") + " · " + names.joined(separator: "\n"))
                                .font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        }
                        if let version = spec.engineVersion { Text(verbatim: L10n.text("运行版本 · " + version)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                        StateLabel(title: services.statusTitle(spec), color: status.color)
                        ServiceOriginDetails(store: store, spec: spec)
                        if !spec.modelID.isEmpty { ModelCapabilityBadge(capabilities: store.serviceCapabilities(spec), prefix: spec.pid == nil ? "启动设置 · " : "当前服务 · ") }
                        if ["splash", "mlx", "llama", "prism"].contains(spec.engineID) { ServiceComponentsView(store: store, spec: spec) }
                        if [.starting, .running, .failed].contains(status) { StartupProgressView(services: services, spec: spec) }
                        HStack(spacing: 8) {
                            Text(verbatim: "http://127.0.0.1:\(spec.port)/v1").font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled)
                            CopyIconButton(help: "复制完整接口地址") { store.copy("http://127.0.0.1:\(spec.port)/v1") }
                        }
                        HStack(spacing: 10) {
                            if spec.pid != nil { Button { store.stop(spec) } label: { Label(L10n.text("停止服务"), systemImage: "stop.fill") }.buttonStyle(AccentButton(destructive: true)).disabled(status == .stopping) }
                            else {
                                Button { store.startServiceInstance(spec) } label: { Label(L10n.text("启动服务"), systemImage: "play.fill") }
                                    .buttonStyle(AccentButton()).disabled(!store.canStartServiceInstance(spec))
                                    .help(L10n.text("按此实例保存的配置启动")).accessibilityIdentifier("start-saved-service-" + spec.id)
                                Button { store.configureService(spec) } label: { Label(L10n.text("配置并启动"), systemImage: "slider.horizontal.3") }.buttonStyle(SecondaryButton())
                            }
                            // Only shown when usable; deletion lives at the bottom of the page, away from the primary action.
                            if status == .running {
                                if store.directConnectionTargets.contains(where: { $0.port == spec.port }) { Button { store.openChat(port: spec.port) } label: { Label(L10n.text("试聊"), systemImage: "bubble.left.and.bubble.right") }.buttonStyle(SecondaryButton()) }
                                Button(L10n.text("打开服务页面")) { store.openEndpoint(spec.port) }.buttonStyle(SecondaryButton())
                            }
                        }
                        if let error = services.errors[spec.id] { Text(verbatim: L10n.text(error)).foregroundStyle(Theme.errorText).font(.system(size: TypeScale.body)) }
                        InstancePerformanceEntry(store: store, performance: store.performance, serviceID: spec.id, port: spec.port)
                        if spec.engineID != "lmstudio" { ServiceParametersView(store: store, services: services, spec: spec).id(spec.id) }
                        if let command = spec.commandText ?? spec.launchArguments.map({ ([spec.engineExecutable ?? ""] + $0).map(ServiceCommand.quote).joined(separator: " ") }) { DisclosureGroup("启动命令") { Text(verbatim: L10n.text(command)).font(.system(size: TypeScale.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) } }
                        if store.serviceModelMissing(spec) {
                            // 模型已被删除：此服务无法再启动，接入入口没有意义，只提供清理。
                            VStack(alignment: .leading, spacing: 10) {
                                Label(L10n.text("模型文件已删除，此服务无法再启动。"), systemImage: "exclamationmark.triangle").font(.system(size: TypeScale.body, weight: .medium)).foregroundStyle(Theme.warningText)
                                Text(verbatim: spec.modelPath).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                                Button(role: .destructive) { store.serviceRemoval = spec } label: { Label(L10n.text("移除服务及相关接入…"), systemImage: "trash") }.buttonStyle(AccentButton(destructive: true))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                        } else if spec.engineID == "mflux" {
                            if status == .running { ImageGenerationView(session: store.imageSession(spec), copy: store.copy, showService: { store.showService(spec) }) }
                        } else { ConnectionEntry(store: store, port: spec.port) }
                        if spec.engineID == "ollama" && status == .running { OllamaLoadedView(store: store, services: services, port: spec.port) }
                        Divider()
                        HStack(spacing: 16) {
                            Text(verbatim: L10n.text("运行日志")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer()
                            Toggle(L10n.text("跟随最新输出"), isOn: $store.followLog).toggleStyle(.checkbox).font(.system(size: TypeScale.callout))
                            Button(L10n.text("在 Finder 中打开")) { store.reveal(services.logURL(spec.id).path) }.buttonStyle(PlainAction()).disabled(!store.canReveal(services.logURL(spec.id).path))
                        }
                        LogView(text: services.log(spec.id), follow: store.followLog)
                        Button(role: .destructive) { store.serviceRemoval = spec } label: { Label(L10n.text("删除服务配置…"), systemImage: "trash") }.buttonStyle(.bordered).disabled(!services.canRemoveConfiguration(spec)).help(L10n.text("保留模型文件和运行日志"))
                    } else {
                        if store.hasServiceFilters {
                            EmptyMessage(symbol: "line.3.horizontal.decrease.circle", title: L10n.text("没有匹配的服务"), detail: "请切换状态或模型基座筛选。")
                            Button(L10n.text("清除筛选")) { store.clearServiceFilters() }.buttonStyle(.bordered)
                        } else {
                            EmptyMessage(symbol: "server.rack", title: L10n.text("服务尚未配置"), detail: "在“运行引擎”选择兼容模型，即可启动本地服务。")
                            Button(L10n.text("启动服务…")) { store.showLaunch = true }.buttonStyle(AccentButton())
                            if !services.external.isEmpty { Text(verbatim: L10n.text("左侧已列出检测到的外部服务。")).foregroundStyle(Theme.muted) }
                        }
                    }
                }.padding(34)
                }
            }.frame(maxWidth: .infinity)
        }
    }
    var serviceSelection: ServiceListSelection? {
        if store.gatewaySelected { return .gateway }
        if let port = store.selectedExternal { return .external(port) }
        return store.selectedServiceID.map { .managed($0) }
    }
    func selectService(_ selection: ServiceListSelection?) {
        switch selection {
        case .gateway: store.gatewaySelected = true; store.synchronizeGateway(); Task { await store.gateway.poll() }
        case .managed(let id): if let spec = services.records.first(where: { $0.id == id }) { store.showService(spec) }
        case .external(let port): store.gatewaySelected = false; store.selectedExternal = port
        case nil: break
        }
    }
    func serviceRow(title: String, detail: String, status: String, color: Color, engine: Engine? = nil, origin: ServiceOrigin? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let engine { EngineIcon(engine: engine, size: 32) } else { SidebarSymbol(symbol: "network") }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1)
                Text(verbatim: L10n.text(detail)).font(.system(size: TypeScale.callout)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) { Circle().fill(color).frame(width: 6, height: 6); Text(verbatim: L10n.text(status)) }.font(.system(size: TypeScale.callout)).foregroundStyle(.secondary)
                if let origin { Text(verbatim: origin.labels.map(L10n.text).joined(separator: " · ")).font(.system(size: TypeScale.caption)).foregroundStyle(origin.uses.isEmpty ? Theme.muted : Theme.linkColor).lineLimit(2).fixedSize(horizontal: false, vertical: true).help((origin.labels + origin.uses.map(\.title)).map(L10n.text).joined(separator: " · ")) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
}
