import SwiftUI
import XAirKit

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var app = app
        Group {
            if sizeClass == .compact {
                TabView(selection: $app.selectedTab) {
                    Tab("Mixer", systemImage: "slider.vertical.3", value: AppTab.mixer) { MixerView() }
                    Tab("Channel", systemImage: "dial.medium", value: AppTab.channel) { ChannelView() }
                    Tab("Effects", systemImage: "sparkles", value: AppTab.effects) { EffectsView() }
                    Tab("Scenes", systemImage: "square.stack.3d.up", value: AppTab.scenes) { ScenesView() }
                    Tab("Tools", systemImage: "square.grid.2x2", value: AppTab.tools) { ToolsView() }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                NavigationSplitView {
                    List(selection: Binding<AppTab?>(get: { app.selectedTab }, set: { if let tab = $0 { app.selectedTab = tab } })) {
                        ForEach([AppTab.mixer, .channel, .effects, .scenes, .routing, .meters, .setup], id: \.self) { tab in
                            Label(tab.rawValue.capitalized, systemImage: tab.symbol).tag(tab)
                        }
                    }
                    .listStyle(.sidebar)
                    .navigationTitle("X Air Modern")
                    .navigationSplitViewColumnWidth(min: 175, ideal: 210, max: 300)
                } detail: {
                    switch app.selectedTab {
                    case .mixer: MixerView()
                    case .channel: ChannelView()
                    case .effects: EffectsView()
                    case .scenes: ScenesView()
                    case .routing: RoutingView()
                    case .meters: MetersView()
                    case .setup, .tools: SetupView()
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onChange(of: sizeClass, initial: true) { _, c in
            app.compactNavigation = c == .compact
            if c == .compact, [.routing, .meters, .setup].contains(app.selectedTab) {
                app.toolsPage = app.selectedTab; app.selectedTab = .tools
            } else if c != .compact, app.selectedTab == .tools {
                app.selectedTab = app.toolsPage ?? .setup
            }
        }
    }
}

private extension AppTab {
    var symbol: String {
        switch self {
        case .mixer: "slider.vertical.3"
        case .channel: "dial.medium"
        case .effects: "sparkles"
        case .scenes: "square.stack.3d.up"
        case .routing: "arrow.triangle.branch"
        case .meters: "chart.bar.xaxis"
        case .setup: "gearshape"
        case .tools: "square.grid.2x2"
        }
    }
}

/// iPhone "Tools" tab: Routing, Meters/RTA and Setup in one navigation stack.
struct ToolsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                NavigationLink(value: AppTab.routing) { Label("Routing", systemImage: "arrow.triangle.branch") }
                NavigationLink(value: AppTab.meters) { Label("Meters and RTA", systemImage: "chart.bar.xaxis") }
                NavigationLink(value: AppTab.setup) { Label("Setup", systemImage: "gearshape") }
            }
            .navigationTitle("Tools")
            .toolbar { SessionToolbar() }
            .navigationDestination(for: AppTab.self) { t in
                switch t {
                case .routing: RoutingView(standalone: false)
                case .meters: MetersView(standalone: false)
                default: SetupView(standalone: false)
                }
            }
            .navigationDestination(item: $app.toolsPage) { t in
                switch t {
                case .routing: RoutingView(standalone: false)
                case .meters: MetersView(standalone: false)
                default: SetupView(standalone: false)
                }
            }
        }
    }
}

/// Screens own a NavigationStack when shown as a tab, or join the parent stack when pushed (iPhone Tools tab).
struct ScreenContainer<Content: View>: View {
    var standalone: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if standalone { NavigationStack { content } } else { content }
    }
}


/// Toolbar content shared by the main screens: connection status, solo indicator, disconnect.
struct SessionToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let d = app.session.device
            Label(app.model.displayName + (app.simulator != nil ? " Sim" : app.offlineEditing ? " Offline" : ""),
                  systemImage: app.offlineEditing ? "icloud.slash" : app.simulator != nil ? "cpu" : "dot.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .fixedSize()
                .accessibilityLabel("Connected to \(d?.name ?? "mixer"), \(app.model.displayName)\(app.simulator != nil ? ", simulator" : "")")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if app.store.bool("/-stat/solo") {
                Button { app.session.set("/-action/clearsolo", index: 1) } label: {
                    Label("Clear solo", systemImage: "s.circle.fill")
                }
                .tint(Theme.solo)
                .accessibilityHint("Solo is active. Clears all solos.")
            }
            Menu {
                if app.offlineEditing {
                    Button("Connect and send edits to a mixer…", systemImage: "arrow.up.circle") { app.disconnect() }
                } else {
                    Button("Resynchronize from mixer", systemImage: "arrow.triangle.2.circlepath") { app.session.resync() }
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { app.disconnect() }
                }
            } label: { Label("Connection", systemImage: "ellipsis.circle") }
        }
    }
}
