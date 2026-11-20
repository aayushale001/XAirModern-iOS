import SwiftUI
import UniformTypeIdentifiers
import XAirKit

struct EffectsView: View {
    @Environment(AppModel.self) private var app
    private var slot: Int { app.selectedFXSlot }
    @State private var exporting: TextDocument?
    @State private var importing = false
    @State private var pendingType: Int?
    @State private var choosingType = false
    @State private var typeSearch = ""

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("FX slot", selection: $app.selectedFXSlot) {
                        ForEach(1...4, id: \.self) { s in Text("FX \(s) · \(app.store.fxTypeName(slot: s))").tag(s) }
                    }
                    .pickerStyle(.segmented)
                    slotHeader
                    slotMeters
                    parameterGrid
                    returnCard
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .meterSubscriptions([3])
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SessionToolbar()
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("Save FX preset…", systemImage: "square.and.arrow.up") {
                            exporting = TextDocument(text: SceneFiles.exportFXPreset(store: app.store, slot: slot))
                        }
                        Button("Load FX preset…", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Label("Presets", systemImage: "tray.full") }
                }
            }
            .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                          document: exporting, contentType: .xairEffect, defaultFilename: "FX\(slot)-\(app.store.fxTypeName(slot: slot))") { app.fileURL($0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.xairEffect, .plainText]) { result in
                guard let url = app.fileURL(result) else { return }
                guard let text = readSecurityScoped(url) else {
                    app.alert = AppAlert(title: "Could not open effect preset", message: url.lastPathComponent)
                    return
                }
                let messages = SceneFiles.importFXPreset(text, into: app.store, slot: slot)
                if messages.isEmpty { app.alert = AppAlert(title: "No effect settings found", message: url.lastPathComponent) }
                else { app.session.pushNodes(messages) }
            }
            .sheet(isPresented: $choosingType) {
                NavigationStack {
                    List {
                        ForEach(Array(app.store.schema.fxTypes.enumerated()), id: \.offset) { i, code in
                            let title = app.store.schema.fxLongNames[i] + " (" + code + ")"
                            if typeSearch.isEmpty || title.localizedCaseInsensitiveContains(typeSearch) {
                                Button {
                                    if app.confirmPopups { pendingType = i } else { applyType(i) }
                                } label: {
                                    HStack {
                                        Text(title)
                                        Spacer()
                                        if i == app.store.index("/fx/\(slot)/type") { Image(systemName: "checkmark") }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .navigationTitle("Choose effect")
                    .searchable(text: $typeSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search effects")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingType = false } } }
                }
                .alert("Change effect type?", isPresented: Binding(get: { pendingType != nil }, set: { if !$0 { pendingType = nil } }), presenting: pendingType) { type in
                    Button("Change", role: .destructive) { applyType(type) }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("The mixer resets this slot’s parameters when the effect type changes.")
                }
            }
        }
    }

    private func applyType(_ type: Int) {
        app.session.set("/fx/\(slot)/type", index: type)
        choosingType = false
    }

    private var slotHeader: some View {
        let typeIdx = app.store.index("/fx/\(slot)/type")
        let names = app.store.schema.fxLongNames
        return Card(title: names.indices.contains(typeIdx) ? names[typeIdx] : app.store.fxTypeName(slot: slot), systemImage: "sparkles") {
            Button {
                typeSearch = ""
                choosingType = true
            } label: {
                Label("Effect type", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Effect type, \(app.store.fxTypeName(slot: slot))")
            HStack {
                ParamPicker(path: "/fx/\(slot)/insert", label: "Usage", labels: ["Send / return", "Insert"])
                Spacer()
                Text(app.store.bool("/fx/\(slot)/insert") ? "Inserted on a channel/bus" : "Fed by FX send \(slot)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var slotMeters: some View {
        let m = app.session.meters
        let start = (slot - 1) * 14
        let indicators = m.effectIndicators(slot: slot, type: app.store.fxTypeName(slot: slot), store: app.store)
        return Card(title: "FX \(slot) meters", systemImage: "waveform") {
            if m.raw(.effects, start) == nil { Text("Waiting for FX meters").foregroundStyle(.secondary) }
            else {
                MeterRow(labels: ["In L", "In R", "Out L", "Out R"],
                         values: [0, 1, 12, 13].map { m.dB(.effects, start + $0) }, height: 68)
                ForEach(indicators) { meter in
                    ProgressView(value: Double(meter.value), total: Double(meter.maximum)) {
                        Text(meter.label).font(.caption)
                    }.tint(.orange).accessibilityValue("\(meter.value) of \(meter.maximum)")
                }
            }
        }
    }

    private var parameterGrid: some View {
        let specs = app.store.fxParamSpecs(slot: slot)
        return Card(title: "Parameters", systemImage: "dial.low") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                ForEach(Array(specs.enumerated()), id: \.offset) { i, spec in
                    let path = String(format: "/fx/%d/par/%02d", slot, i + 1)
                    if case .enumeration = spec.kind {
                        VStack(spacing: 4) {
                            ParamPicker(path: path, label: spec.label ?? "Param \(i + 1)")
                            Text(spec.label ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        ParamKnob(path: path, label: spec.label ?? "Param \(i + 1)", size: 58, tint: .purple)
                    }
                }
            }
        }
    }

    private var returnCard: some View {
        let rtn = "/rtn/\(slot)"
        return Card(title: "FX \(slot) return and send", systemImage: "arrow.uturn.backward") {
            ParamSlider(path: rtn + "/mix/fader", label: "Return level", unit: "dB")
            StripMute(strip: 16 + slot)
            ParamSlider(path: "/fxsend/\(slot)/mix/fader", label: "FX send master", unit: "dB")
        }
    }
}

// MARK: Files

extension UTType {
    static let xairScene = UTType(exportedAs: "com.example.xairmodern.scene", conformingTo: .plainText)
    static let xairChannel = UTType(exportedAs: "com.example.xairmodern.channel", conformingTo: .plainText)
    static let xairEffect = UTType(exportedAs: "com.example.xairmodern.effect", conformingTo: .plainText)
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .xairScene, .xairChannel, .xairEffect] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

func readSecurityScoped(_ url: URL) -> String? {
    readSecurityScopedData(url, limit: 4_000_000).flatMap { String(data: $0, encoding: .utf8) }
}

func readSecurityScopedData(_ url: URL, limit: Int = 64_000_000) -> Data? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    do {
        let length = try handle.seekToEnd()
        guard length < UInt64(limit) else { return nil }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: Int(length) + 1) ?? Data()
        return data.count == Int(length) ? data : nil
    } catch {
        return nil
    }
}
