import SwiftUI
import XAirKit

enum RoutingTab: String, CaseIterable, Identifiable {
    case inputs = "Inputs", aux = "Aux out", main = "Main / Phones", usbSend = "USB send", ultranet = "Ultranet", usbReturn = "USB return"
    var id: String { rawValue }
}

struct RoutingView: View {
    @Environment(AppModel.self) private var app
    var standalone = true
    @State private var tab: RoutingTab = .inputs
    @State private var exporting: TextDocument?
    @State private var importing = false
    @State private var importText: String?
    @State private var pendingPreset: RoutingPreset?
    @State private var scopes = Set(RoutingScope.allCases)
    @State private var choosingScopes = false
    @State private var choosingPreset = false
    @State private var chosenPreset: RoutingPreset?

    var presets: [RoutingPreset] {
        guard app.model.hasUSBAudioInterface else { return [] }
        let builtins = BuiltinPresets.shared
        switch tab {
        case .usbReturn: return builtins.usbReturn
        case .usbSend: return builtins.usbSend
        case .ultranet: return builtins.ultranet
        default: return []
        }
    }

    var tabs: [RoutingTab] {
        app.model.hasUltranetAndUSBRouting ? RoutingTab.allCases : [.inputs, .aux, .main]
    }

    var body: some View {
        ScreenContainer(standalone: standalone) {
            List {
                ChipPicker(items: tabs, title: { $0.rawValue }, selection: $tab)
                    .accessibilityIdentifier("routing-tabs")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                if !presets.isEmpty {
                    Button("Built-in presets", systemImage: "list.bullet") { choosingPreset = true }
                }
                switch tab {
                case .inputs: inputs
                case .aux: outputs(prefix: "/routing/aux", count: 6, active: app.model.auxOutputCount, title: "Aux")
                case .main: mainOuts
                case .usbSend: outputs(prefix: "/routing/usb", count: 18, active: 18, title: "USB")
                case .ultranet: outputs(prefix: "/routing/p16", count: 16, active: 16, title: "Ultranet")
                case .usbReturn: usbReturns
                }
            }
            .navigationTitle("Routing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SessionToolbar()
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("Export routing…", systemImage: "square.and.arrow.up") { exporting = TextDocument(text: SceneFiles.exportRouting(store: app.store)) }
                        Button("Import routing…", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Label("Routing file", systemImage: "doc") }
                }
            }
            .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                          document: exporting, contentType: .xairScene, defaultFilename: "Routing") { app.fileURL($0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.xairScene, .plainText]) { r in
                guard let url = app.fileURL(r) else { return }
                guard let text = readSecurityScoped(url) else {
                    app.alert = AppAlert(title: "Could not open routing file", message: url.lastPathComponent)
                    return
                }
                importText = text
                scopes = Set(RoutingScope.available(on: app.model))
                choosingScopes = true
            }
            .sheet(isPresented: $choosingPreset, onDismiss: {
                guard let preset = chosenPreset else { return }
                chosenPreset = nil
                if app.confirmPopups { pendingPreset = preset }
                else { apply(preset.lines.joined(separator: "\n"), scopes: Set(RoutingScope.allCases)) }
            }) {
                NavigationStack {
                    List(presets) { preset in
                        Button(preset.title) { chosenPreset = preset; choosingPreset = false }
                    }
                    .navigationTitle(tab.rawValue + " presets")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingPreset = false } } }
                }.presentationDetents([.medium, .large])
            }
            .confirmationDialog("Apply " + (pendingPreset?.title ?? "preset") + "?", isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }), presenting: pendingPreset) { preset in
                Button("Apply preset") { apply(preset.lines.joined(separator: "\n"), scopes: Set(RoutingScope.allCases)) }
            }
            .sheet(isPresented: $choosingScopes) {
                NavigationStack {
                    Form {
                        ForEach(RoutingScope.available(on: app.model)) { scope in
                            Toggle(scope.rawValue, isOn: Binding(get: { scopes.contains(scope) }, set: { on in
                                if on { scopes.insert(scope) } else { scopes.remove(scope) }
                            }))
                        }
                    }.navigationTitle("Recall routing")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingScopes = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Recall") { apply(importText ?? "", scopes: scopes); choosingScopes = false }.disabled(scopes.isEmpty)
                        }
                    }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: app.model) { if !tabs.contains(tab) { tab = .inputs } }
        }
    }

    private func apply(_ text: String, scopes: Set<RoutingScope>) {
        let messages = SceneFiles.importRouting(text, into: app.store, scopes: scopes)
        if messages.isEmpty {
            app.alert = AppAlert(title: "No matching routes", message: "The file contains no routes for the selected model and recall scopes.")
        } else { app.session.pushNodes(messages) }
    }

    private var inputs: some View {
        Section {
            ForEach(0..<app.model.channelCount, id: \.self) { ch in
                let base = String(format: "/ch/%02d", ch + 1)
                HStack {
                    Text(app.stripName(ch)).frame(width: 90, alignment: .leading)
                    ParamPicker(path: base + "/config/insrc", label: "Source",
                                labels: (0..<19).map { app.model.inputSourceLabel(index: $0) }, indices: app.model.inputSourceIndices)
                }
            }
        } header: { Text("Channel inputs") } footer: {
            Text(app.model == .xr16 ? "Inputs 9-16 are line inputs." : app.model == .xr12 ? "Inputs 5-12 are line inputs." : "Inputs 17/18 are the aux input.")
        }
    }

    private func outputs(prefix: String, count: Int, active: Int, title: String) -> some View {
        Section {
            ForEach(1...count, id: \.self) { n in
                let p = prefix + String(format: "/%02d", n)
                VStack(alignment: .leading) {
                    Text("\(title) \(n)").font(.subheadline.weight(.semibold))
                    HStack {
                        ParamPicker(path: p + "/src", label: "Source")
                        ParamPicker(path: p + "/pos", label: "Tap", labels: app.store.schema.labels["routingTaps"])
                    }
                }
                .disabled(n > active)
                .opacity(n <= active ? 1 : 0.45)
                .accessibilityHint(n <= active ? "" : "This output is not present on \(app.model.displayName)")
            }
        } header: { Text("\(title) outputs") }
    }

    private var mainOuts: some View {
        Section("Main and phones outputs") {
            HStack { Text("Main out"); ParamPicker(path: "/routing/main/01/src", label: "Source") }
            HStack { Text("Phones / monitor"); ParamPicker(path: "/routing/main/02/src", label: "Source") }
        }
    }

    private var usbReturns: some View {
        Section {
            ForEach(0..<16, id: \.self) { ch in
                let base = String(format: "/ch/%02d", ch + 1)
                HStack {
                    Text(app.stripName(ch)).frame(width: 90, alignment: .leading)
                    ParamToggle(path: base + "/preamp/rtnsw", label: "USB", compact: true).frame(width: 70)
                    ParamPicker(path: base + "/config/rtnsrc", label: "Return")
                }
            }
            HStack { Text("Aux"); ParamToggle(path: "/rtn/aux/preamp/rtnsw", label: "USB", compact: true).frame(width: 70); ParamPicker(path: "/rtn/aux/config/rtnsrc", label: "Return") }
        } header: { Text("USB returns to channels") }
    }
}
