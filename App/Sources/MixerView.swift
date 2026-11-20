import SwiftUI
import XAirKit

struct MixerView: View {
    @Environment(AppModel.self) private var app
    @State private var pasteTarget: Int?

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            VStack(spacing: 0) {
                layerBar
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(app.visibleStrips(for: app.mixerLayer), id: \.self) { s in
                            StripView(strip: s, onPaste: { pasteTarget = s })
                        }
                        Divider()
                        MainStripView()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.visible)
            }
            .navigationTitle("Mixer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SessionToolbar() }
            .meterSubscriptions(app.visibleStrips(for: app.mixerLayer).contains(where: { $0 >= 32 }) ? [8] : [])
            .sheet(item: Binding(get: { pasteTarget.map(IdentifiedInt.init) }, set: { pasteTarget = $0?.value })) { t in
                PasteSheet(target: t.value)
            }
        }
    }

    private var layerBar: some View {
        @Bindable var app = app
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Picker("Layer", selection: $app.mixerLayer) {
                    ForEach(MixerLayer.primary) { Text($0.title).tag($0) }
                    ForEach(0..<4) { d in Text("DCA \(d + 1) Spill").tag(MixerLayer.dcaSpill(d)) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Fader layer")
                Picker("Sends on fader", selection: $app.sendsOnFader) {
                    Text("Main mix").tag(Int?.none)
                    ForEach(0..<6) { b in Text("Bus \(b + 1) sends").tag(Int?.some(b)) }
                    ForEach(6..<10) { f in Text("FX \(f - 5) sends").tag(Int?.some(f)) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Sends on fader")
                if app.sendsOnFader != nil {
                    Label("Sends on fader", systemImage: "arrow.up.right.circle.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular.tint(.purple.opacity(0.35)), in: .capsule)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }
}

struct IdentifiedInt: Identifiable { let value: Int; var id: Int { value } }

/// One channel strip: name/colour, fader (or send level), meter, mute, solo, pan, select.
struct StripView: View {
    @Environment(AppModel.self) private var app
    let strip: Int
    var faderHeight: CGFloat = 260
    var onPaste: () -> Void = {}
    @ScaledMetric(relativeTo: .caption) private var stripWidth: CGFloat = 70

    var base: String { AppModel.base(of: strip) }
    var isDCA: Bool { strip >= 32 }

    /// Fader path: main fader, or the channel's send to the selected bus/FX (sends on fader).
    var faderPath: String {
        if isDCA { return base + "/fader" }
        if let b = app.sendsOnFader, strip < 21 { return base + String(format: "/mix/%02d/level", b + 1) }
        return base + "/mix/fader"
    }

    var body: some View {
        let color = app.stripColor(strip)
        let selected = app.selectedStrip == strip
        VStack(spacing: 8) {
            Button {
                app.selectedStrip = strip
            } label: {
                Text(app.stripName(strip))
                    .font(.body.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundStyle(Theme.isInverted(color) ? Theme.channelColor(color) : Color.onChannel(color))
                    .background(Theme.isInverted(color) ? Color.black : Theme.channelColor(color), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(app.stripName(strip))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("Edit channel", systemImage: "dial.medium") { app.selectedStrip = strip; app.selectedTab = .channel }
                if !isDCA {
                    Button("Copy channel", systemImage: "doc.on.doc") { app.copyStrip(strip) }
                    Button("Paste…", systemImage: "doc.on.clipboard") { onPaste() }.disabled(app.clipboard == nil)
                }
            }

            if !isDCA, strip < 21 || strip == 31 || (21..<31).contains(strip) {
                if app.store.spec(base + "/mix/pan") != nil {
                    ParamKnob(path: base + "/mix/pan", label: "\(app.stripName(strip)) pan", size: 40, showsText: false)
                }
            }

            LevelFader(path: faderPath, label: "\(app.stripName(strip)) \(app.sendsOnFader == nil ? "fader" : "send")",
                       strip: strip,
                       tint: app.sendsOnFader == nil ? .accentColor : .purple)
                .frame(height: faderHeight)

            Text(app.store.display(faderPath))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)


            StripMute(strip: strip, compact: true)
            if let soloIndex = soloIndex {
                SoloButton(strip: strip, path: String(format: "/-stat/solosw/%02d", soloIndex))
            }
            if strip < 31, !isDCA, app.store.spec(base + "/mix/lr") != nil {
                ParamToggle(path: base + "/mix/lr", label: "LR", compact: true)
            }
        }
        .frame(minWidth: stripWidth, maxWidth: stripWidth * 1.4)
        .padding(6)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    /// /-stat/solosw index (1-based) from solo_setupcuemix: 1-16 ch, 17 aux, 18-21 FX rtn,
    /// 22-27 bus, 28-31 FX send, 32 LR. No DCA mapping is evidenced, so DCAs have no solo.
    var soloIndex: Int? { strip < 32 ? strip + 1 : nil }


}

struct MainStripView: View {
    @Environment(AppModel.self) private var app
    var faderHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 8) {
            Text(app.stripName(31))
                .font(.body.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 28)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            ParamKnob(path: "/lr/mix/pan", label: "Main balance", size: 40, showsText: false)
            LevelFader(path: "/lr/mix/fader", label: "Main LR fader",
                       strip: 31)
                .frame(height: faderHeight)
            Text(app.store.display("/lr/mix/fader")).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            StripMute(strip: 31, compact: true)
            SoloButton(strip: 31, path: "/-stat/solosw/32")
        }
        .frame(width: 96)
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

struct PasteSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: Int
    @State private var scopes: Set<PasteScope> = [.eq, .dynamics]

    var body: some View {
        NavigationStack {
            Form {
                Section("Paste into \(app.stripName(target))") {
                    ForEach(PasteScope.allCases) { s in
                        Toggle(s.title, isOn: Binding(get: { scopes.contains(s) }, set: { on in
                            if on { scopes.insert(s) } else { scopes.remove(s) }
                        }))
                    }
                }
            }
            .navigationTitle("Paste")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Paste") { app.paste(into: target, scopes: scopes); dismiss() }.disabled(scopes.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SoloButton: View {
    @Environment(AppModel.self) private var app
    let strip: Int
    let path: String
    var body: some View {
        let on = app.store.bool(path)
        Button { app.toggleSolo(strip: strip) } label: {
            Text("Solo").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(on ? Theme.solo : .secondary)
        .background(on ? Theme.solo.opacity(0.28) : .clear, in: .capsule)
        .accessibilityLabel("Solo \(app.stripName(strip))")
        .accessibilityValue(on ? "On" : "Off")
    }
}
