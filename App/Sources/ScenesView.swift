import UniformTypeIdentifiers
import SwiftUI
import XAirKit

struct ScenesView: View {
    @Environment(AppModel.self) private var app
    @State private var selected = 1
    @State private var newName = ""
    @State private var confirmLoad: Int?
    @State private var confirmSave: Int?
    @State private var confirmDelete: Int?
    @State private var editingScope: Int?
    @State private var renameTarget: Int?
    @State private var renameText = ""
    @State private var exportType: UTType = .xairScene
    @State private var exporting: TextDocument?
    @State private var exportName = "Scene"
    @State private var showImporter = false
    @State private var importKind: ImportKind?
    @State private var presetScope: PresetScope = .complete

    enum ImportKind: Identifiable { case scene, channel; var id: Int { self == .scene ? 0 : 1 } }

    var body: some View {
        NavigationStack {
            List {
                snapshots
                files
                presets
            }
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SessionToolbar() }
            .confirmationDialog("Load snapshot \(confirmLoad ?? 0)?", isPresented: binding($confirmLoad), presenting: confirmLoad) { n in
                Button("Load") { load(n) }
            } message: { _ in Text("Current mixer settings in the recall scope will be replaced.") }
            .confirmationDialog("Overwrite snapshot \(confirmSave ?? 0)?", isPresented: binding($confirmSave), presenting: confirmSave) { n in
                Button("Save", role: .destructive) { save(n) }
            }
            .confirmationDialog("Delete snapshot \(confirmDelete ?? 0)?", isPresented: binding($confirmDelete), presenting: confirmDelete) { n in
                Button("Delete", role: .destructive) { app.session.command("/-snap/delete", [.int(Int32(n))]); app.session.requestNode(String(format: "/-snap/%02d", n)) }
            }
            .alert("Rename snapshot", isPresented: binding($renameTarget), presenting: renameTarget) { n in
                TextField("Snapshot name", text: $renameText)
                Button("Rename") { app.session.set(String(format: "/-snap/%02d/name", n), string: renameText) }.disabled(renameText.isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: Binding(get: { editingScope.map(IdentifiedInt.init) }, set: { editingScope = $0?.value })) { s in
                ScopeEditor(snapshot: s.value)
            }
            .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                          document: exporting, contentType: exportType, defaultFilename: exportName) { app.fileURL($0) }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.xairScene, .xairChannel, .plainText]) { r in
                guard let url = app.fileURL(r) else { return }
                guard let text = readSecurityScoped(url) else {
                    app.alert = AppAlert(title: "Could not open mixer file", message: url.lastPathComponent)
                    return
                }
                if importKind == .scene { app.importScene(text) }
                else {
                    let messages = SceneFiles.importChannelPreset(text, into: app.store, channel: AppModel.base(of: app.selectedStrip))
                    if messages.isEmpty { app.alert = AppAlert(title: "No matching channel settings", message: url.lastPathComponent) }
                    else { app.session.pushNodes(messages) }
                }
                importKind = nil
            }
        }
    }

    private func binding(_ v: Binding<Int?>) -> Binding<Bool> {
        Binding(get: { v.wrappedValue != nil }, set: { if !$0 { v.wrappedValue = nil } })
    }

    private var snapshots: some View {
        Section {
            HStack {
                TextField("Snapshot name", text: $newName).textFieldStyle(.roundedBorder)
                Button("Save to \(selected)") {
                    if app.store.string(String(format: "/-snap/%02d/name", selected)).isEmpty || !app.confirmPopups { save(selected) } else { confirmSave = selected }
                }
                .buttonStyle(.glassProminent)
                .disabled(newName.isEmpty)
            }
            ForEach(1...64, id: \.self) { n in
                let name = app.store.string(String(format: "/-snap/%02d/name", n))
                let current = app.store.index("/-snap/index") == n
                HStack {
                    Text(String(format: "%02d", n)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    Text(name.isEmpty ? "—" : name).fontWeight(current ? .bold : .regular)
                    if current { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Current") }
                    Spacer()
                    if !name.isEmpty {
                        Button("Load") { app.confirmPopups ? (confirmLoad = n) : load(n) }.buttonStyle(.bordered)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = n; newName = name }
                .listRowBackground(selected == n ? Color.accentColor.opacity(0.12) : nil)
                .swipeActions {
                    if !name.isEmpty {
                        Button("Delete", role: .destructive) { confirmDelete = n }
                        Button("Scope") { editingScope = n }.tint(.indigo)
                        Button("Rename") { renameText = name; renameTarget = n }.tint(.blue)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Load") { if !name.isEmpty { confirmLoad = n } }
                .accessibilityAction(named: "Edit recall scope") { editingScope = n }
            }
        } header: {
            Text("Mixer snapshots")
        } footer: {
            Text("Snapshots are stored on the mixer (/-snap). Swipe a snapshot to edit its recall scope (safes) or delete it.")
        }
    }

    private var files: some View {
        Section("Scene files") {
            Button("Export current scene…", systemImage: "square.and.arrow.up") {
                exportType = .xairScene
                exportName = app.store.string("/-prefs/name").isEmpty ? "Scene" : app.store.string("/-prefs/name")
                exporting = TextDocument(text: SceneFiles.exportScene(store: app.store))
            }
            Button("Import scene file into mixer…", systemImage: "square.and.arrow.down") { importKind = .scene; showImporter = true }
        }
    }

    private var presets: some View {
        Section {
            Picker("Preset scope", selection: $presetScope) {
                ForEach(PresetScope.allCases) { Text($0.title).tag($0) }
            }
            Button("Save \(app.stripName(app.selectedStrip)) preset…", systemImage: "square.and.arrow.up") {
                exportType = .xairChannel
                exportName = app.stripName(app.selectedStrip) + "-" + presetScope.rawValue
                exporting = TextDocument(text: SceneFiles.exportChannelPreset(store: app.store, channel: AppModel.base(of: app.selectedStrip), scope: presetScope))
            }
            Button("Load preset into \(app.stripName(app.selectedStrip))…", systemImage: "square.and.arrow.down") { importKind = .channel; showImporter = true }
            Button("Copy \(app.stripName(app.selectedStrip))", systemImage: "doc.on.doc") { app.copyStrip(app.selectedStrip) }
        } header: { Text("Channel presets") } footer: {
            Text("Channel presets apply to the channel selected in the Mixer. Paste a copied channel from a strip's context menu.")
        }
    }

    private func load(_ n: Int) {
        app.session.command("/-snap/load", [.int(Int32(n))])
        // The mixer changes many values at once; read the whole state back.
        Task { try? await Task.sleep(for: .milliseconds(300)); app.session.resync() }
    }

    private func save(_ n: Int) {
        app.session.set("/-snap/name", string: newName)
        app.session.command("/-snap/save", [.int(Int32(n))])
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            app.session.requestNode(String(format: "/-snap/%02d", n))
            app.session.requestNode("/-snap")
        }
    }
}

struct ScopeEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let snapshot: Int
    @State private var scope = SnapshotScope(all: true)

    var body: some View {
        let labels = app.store.schema.labels["snapshotScope"] ?? []
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("All") { scope = SnapshotScope(all: true) }
                        Button("None") { scope = SnapshotScope(all: false) }
                    }
                    .buttonStyle(.bordered)
                }
                Section("Channels (safes are the switched-off items)") { rows(0..<36, labels) }
                Section("Effects") { rows(36..<40, labels) }
                Section("Parameters") { rows(40..<min(59, labels.count), labels) }
            }
            .navigationTitle("Recall scope \(snapshot)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.session.set(String(format: "/-snap/%02d/scope", snapshot), string: scope.string)
                        dismiss()
                    }
                    .disabled(!scope.isValid)
                }
            }
            .onAppear { scope = SnapshotScope(string: app.store.string(String(format: "/-snap/%02d/scope", snapshot))) }
            .safeAreaInset(edge: .bottom) {
                if !scope.isValid {
                    Text("Please select at least one snapshot recall scope.").font(.footnote).padding().glassEffect()
                }
            }
        }
    }

    private func rows(_ r: Range<Int>, _ labels: [String]) -> some View {
        ForEach(r, id: \.self) { i in
            Toggle(i < labels.count ? labels[i] : "Item \(i + 1)", isOn: Binding(get: { scope.flags[i] }, set: { scope.flags[i] = $0 }))
        }
    }
}
