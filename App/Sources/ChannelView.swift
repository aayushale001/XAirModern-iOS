import SwiftUI
import XAirKit

enum ChannelSection: String, CaseIterable, Identifiable {
    case input = "Input", gate = "Gate", dynamics = "Dynamics", eq = "EQ", insert = "Insert", sends = "Sends", main = "Main", config = "Config"
    var id: String { rawValue }
}

struct ChannelView: View {
    @Environment(AppModel.self) private var app
    private var section: ChannelSection { app.channelSection }

    var base: String { AppModel.base(of: app.selectedStrip) }
    var strip: Int { app.selectedStrip }

    var availableSections: [ChannelSection] {
        let s = strip
        var out: [ChannelSection] = []
        if s < 21 { out.append(.input) }
        if s < 16 { out.append(.gate) }
        if s < 16 || (21..<27).contains(s) || s == 31 { out.append(.dynamics) }
        if s < 27 || s == 31 { out.append(.eq) }
        if s < 16 || (21..<27).contains(s) || s == 31 { out.append(.insert) }
        if s < 31 { out.append(.sends) }
        if s < 36 { out.append(.main) }
        out.append(.config)
        return out
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    channelHeader
                    ChipPicker(items: availableSections, title: { $0.rawValue }, selection: $app.channelSection)
                    sectionContent
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(app.stripName(strip))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SessionToolbar() }
            .meterSubscriptions(strip < 32 ? [0, 3, 7] : [8])
            .onChange(of: app.selectedStrip, initial: true) { if !availableSections.contains(section) { app.channelSection = availableSections.first ?? .config } }
        }
    }

    private var channelHeader: some View {
        @Bindable var app = app
        return HStack {
            Button { app.selectedStrip = max(0, strip - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.glass).accessibilityLabel("Previous channel")
            Picker("Channel", selection: $app.selectedStrip) {
                ForEach(0..<36, id: \.self) { s in
                    if s >= 16 || s < app.model.channelCount { Text(app.stripName(s)).tag(s) }
                }
            }
            .pickerStyle(.menu)
            Button { app.selectedStrip = min(35, strip + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.glass).accessibilityLabel("Next channel")
            Spacer()
            if strip < 36 {
                StripMute(strip: strip).frame(width: 110)
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .input: InputSection(base: base, strip: strip)
        case .gate: GateSection(base: base, strip: strip)
        case .dynamics: DynamicsSection(base: base, strip: strip)
        case .eq: EQSection(base: base, strip: strip)
        case .insert: InsertSection(base: base)
        case .sends:
            if strip < 21 { SendsSection(base: base, strip: strip) }
            else {
                Card(title: "Sends to " + app.stripName(strip), systemImage: "arrow.down.left") {
                    ForEach(0..<21, id: \.self) { source in
                        let n = strip - 20
                        let p = AppModel.base(of: source) + String(format: "/mix/%02d", n)
                        ParamPicker(path: p + "/tap", label: app.stripName(source) + " tap",
                                    onSelect: { app.session.setSendTap(strip: source, send: n, index: $0) })
                        ParamSlider(path: p + "/level", label: app.stripName(source), unit: "dB")
                    }
                }
            }
        case .main: MainSection(base: base, strip: strip)
        case .config: ConfigSection(base: base, strip: strip)
        }
    }
}

/// Horizontally scrolling glass chip selector (segmented controls truncate on iPhone).
struct ChipPicker<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { s in
                        Button { selection = s } label: {
                            Text(title(s))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == s ? Color.white : Color.primary)
                        .glassEffect(selection == s ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
                        .accessibilityAddTraits(selection == s ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Input

struct InputSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    let strip: Int

    var body: some View {
        let model = app.model
        let src = app.store.index(base + "/config/insrc")
        let headamp = strip < 16 ? model.headampIndex(forInputSource: src) : nil
        VStack(spacing: 16) {
            if strip < 16 {
                Card(title: "Source", systemImage: "cable.connector") {
                    ParamPicker(path: base + "/config/insrc", label: "Input",
                                labels: (0..<19).map { model.inputSourceLabel(index: $0) }, indices: model.inputSourceIndices)
                    if model.hasUSBAudioInterface {
                        ParamToggle(path: base + "/preamp/rtnsw", label: "USB return", systemImage: "cable.connector.horizontal")
                        ParamPicker(path: base + "/config/rtnsrc", label: "USB return source")
                    }
                }
            } else if strip == 16 && model.hasUSBAudioInterface {
                Card(title: "Source", systemImage: "cable.connector") {
                    if model.hasUSBAudioInterface && strip == 16 { ParamPicker(path: base + "/config/rtnsrc", label: "Aux USB source") }
                    if model.hasUSBAudioInterface, strip == 16 { ParamToggle(path: base + "/preamp/rtnsw", label: "USB return") }
                }
            }
            SelectedLevels(stereo: strip >= 16)
            Card(title: "Preamp", systemImage: "waveform") {
                if let ha = headamp {
                    let hp = String(format: "/headamp/%02d", ha)
                    HStack(spacing: 20) {
                        ParamKnob(path: hp + "/gain", label: MixerModel.headampIsMic(ha) ? "Gain" : "Line gain", unit: "dB", size: 72)
                        if MixerModel.headampIsMic(ha) {
                            ParamToggle(path: hp + "/phantom", label: "+48V", systemImage: "bolt.fill", tint: .red)
                        }
                    }
                    Text("Headamp \(ha)" + (MixerModel.headampIsMic(ha) ? " (mic preamp)" : " (line input)")).font(.footnote).foregroundStyle(.secondary)
                } else if strip < 16 {
                    Text("This source has no preamp.").font(.footnote).foregroundStyle(.secondary)
                }
                if app.store.spec(base + "/preamp/rtntrim") != nil {
                    ParamKnob(path: base + "/preamp/rtntrim", label: "Trim", unit: "dB")
                }
                if app.store.spec(base + "/preamp/invert") != nil {
                    HStack {
                        ParamToggle(path: base + "/preamp/invert", label: "Polarity Ø", systemImage: "circle.slash")
                        ParamToggle(path: base + "/preamp/hpon", label: "Low cut", systemImage: "line.diagonal")
                    }
                    ParamSlider(path: base + "/preamp/hpf", label: "Low cut frequency", unit: "Hz")
                }
            }
        }
    }
}

// MARK: Gate

struct GateSection: View {
    let base: String
    let strip: Int
    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Gate", systemImage: "door.left.hand.open") {
                HStack {
                    ParamToggle(path: base + "/gate/on", label: "Gate on")
                    ParamPicker(path: base + "/gate/mode", label: "Mode", labels: ["Exp 2:1", "Exp 3:1", "Exp 4:1", "Gate", "Ducker"])
                }
                DynamicsGraph(base: base + "/gate", isGate: true).frame(height: 160)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ParamKnob(path: base + "/gate/thr", label: "Threshold", unit: "dB")
                    ParamKnob(path: base + "/gate/range", label: "Range", unit: "dB")
                    ParamKnob(path: base + "/gate/attack", label: "Attack", unit: "ms")
                    ParamKnob(path: base + "/gate/hold", label: "Hold", unit: "ms")
                    ParamKnob(path: base + "/gate/release", label: "Release", unit: "ms")
                }
                ParamPicker(path: base + "/gate/keysrc", label: "Key source")
                KeySolo(strip: strip, gate: true)
            }
            SelectedLevels(stereo: false, keyIndex: 6, reductionIndex: 2)
            SideChainFilterCard(base: base + "/gate/filter")
        }
    }
}

struct KeySolo: View {
    @Environment(AppModel.self) private var app
    let strip: Int
    let gate: Bool

    var body: some View {
        if let index = app.session.keySoloIndex(strip: strip, gate: gate) {
            let path = "/-stat/keysolo"
            Toggle("Listen to side-chain", isOn: Binding(get: { app.store.index(path) == index },
                                                        set: { app.session.set(path, index: $0 ? index : 0) }))
        }
    }
}

struct SideChainFilterCard: View {
    let base: String
    var body: some View {
        Card(title: "Side-chain filter", systemImage: "line.3.horizontal.decrease") {
            HStack {
                ParamToggle(path: base + "/on", label: "Filter on")
                ParamPicker(path: base + "/type", label: "Type")
            }
            ParamSlider(path: base + "/f", label: "Frequency", unit: "Hz")
        }
    }
}

// MARK: Dynamics

struct DynamicsSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    let strip: Int
    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Compressor", systemImage: "rectangle.compress.vertical") {
                HStack {
                    ParamToggle(path: base + "/dyn/on", label: "Dynamics on")
                    ParamPicker(path: base + "/dyn/mode", label: "Mode", labels: ["Comp", "Exp"])
                    ParamToggle(path: base + "/dyn/auto", label: "Auto time")
                }
                DynamicsGraph(base: base + "/dyn", isGate: false).frame(height: 160)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ParamKnob(path: base + "/dyn/thr", label: "Threshold", unit: "dB")
                    ParamKnob(path: base + "/dyn/knee", label: "Knee")
                    ParamKnob(path: base + "/dyn/mgain", label: "Gain", unit: "dB")
                    ParamKnob(path: base + "/dyn/attack", label: "Attack", unit: "ms")
                    ParamKnob(path: base + "/dyn/hold", label: "Hold", unit: "ms")
                    ParamKnob(path: base + "/dyn/release", label: "Release", unit: "ms")
                    ParamKnob(path: base + "/dyn/mix", label: "Mix", unit: "%")
                }
                HStack {
                    ParamPicker(path: base + "/dyn/ratio", label: "Ratio")
                    ParamPicker(path: base + "/dyn/det", label: "Detector")
                    ParamPicker(path: base + "/dyn/env", label: "Envelope")
                }
                if app.store.spec(base + "/dyn/keysrc") != nil { ParamPicker(path: base + "/dyn/keysrc", label: "Key source") }
                KeySolo(strip: strip, gate: false)
            }
            if app.store.spec(base + "/dyn/filter/on") != nil { SideChainFilterCard(base: base + "/dyn/filter") }
            SelectedLevels(stereo: strip == 31, keyIndex: 7, reductionIndex: 3)
        }
    }
}

// MARK: Insert

struct InsertSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    var body: some View {
        Card(title: "Insert effect", systemImage: "arrow.down.right.and.arrow.up.left") {
            HStack {
                ParamToggle(path: base + "/insert/on", label: "Insert on")
                ParamPicker(path: base + "/insert/sel", label: "FX slot")
            }
            Text("Only FX slots configured as inserts process inserted signals. Configure slots in Effects.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: Sends

struct SendsSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    let strip: Int
    var body: some View {
        Card(title: "Sends", systemImage: "arrow.up.right") {
            ForEach(1...10, id: \.self) { n in
                let p = base + String(format: "/mix/%02d", n)
                let name = n <= 6 ? app.stripName(20 + n) : "FX \(n - 6)"
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(name).font(.subheadline.weight(.semibold)).frame(width: 90, alignment: .leading)
                        ParamPicker(path: p + "/tap", label: "Tap", onSelect: { app.session.setSendTap(strip: strip, send: n, index: $0) })
                        if app.store.index(p + "/tap") == 5 {
                            ParamToggle(path: p + "/grpon", label: "Assign", compact: true)
                                .accessibilityHint("Assign to this subgroup")
                        }
                    }
                    ParamSlider(path: p + "/level", label: "Level", unit: "dB")
                    if app.store.spec(p + "/pan") != nil {
                        ParamSlider(path: p + "/pan", label: "Pan")
                    }
                }
                Divider()
            }
        }
    }
}

// MARK: Main / groups

struct MainSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    let strip: Int
    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Main", systemImage: "speaker.wave.2") {
                let fader = strip >= 32 ? base + "/fader" : base + "/mix/fader"
                ParamSlider(path: fader, label: "Fader", unit: "dB")
                if app.store.spec(base + "/mix/pan") != nil { ParamSlider(path: base + "/mix/pan", label: "Pan") }
                if app.store.spec(base + "/mix/lr") != nil { ParamToggle(path: base + "/mix/lr", label: "Assign to Main LR") }
            }
            if app.store.spec(base + "/grp/dca") != nil {
                Card(title: "Groups", systemImage: "rectangle.3.group") {
                    Text("DCA").font(.subheadline)
                    BitmaskToggles(path: base + "/grp/dca", labels: (1...4).map { "DCA \($0)" })
                    Text("Mute groups").font(.subheadline)
                    BitmaskToggles(path: base + "/grp/mute", labels: (1...4).map { "Mute \($0)" }, tint: Theme.mute)
                }
            }
            if strip < 16 {
                Card(title: "Automix", systemImage: "wand.and.stars") {
                    ParamPicker(path: base + "/automix/group", label: "Automix group", labels: ["Off", "X", "Y"])
                    ParamSlider(path: base + "/automix/weight", label: "Weight", unit: "dB")
                }
            }
        }
    }
}

// MARK: Config

struct ConfigSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    let strip: Int
    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Name and colour", systemImage: "tag") {
                ParamTextField(path: base + "/config/name", label: "Name")
                    .textFieldStyle(.roundedBorder)
                ColorPickerRow(path: base + "/config/color")
            }
            if strip < 16 || (21..<27).contains(strip) {
                Card(title: "Stereo link", systemImage: "link") {
                    let isBus = strip >= 21
                    let n = isBus ? strip - 20 : strip + 1
                    let a = n % 2 == 1 ? n : n - 1
                    ParamToggle(path: (isBus ? "/config/buslink/" : "/config/chlink/") + "\(a)-\(a + 1)",
                                label: "\(isBus ? "Bus" : "Ch") \(a)-\(a + 1) linked", systemImage: "link")
                    Text("Linked pairs share settings according to the link preferences (Setup ▸ Global). Name, source, pan, key source and insert slot stay independent.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ColorPickerRow: View {
    @Environment(AppModel.self) private var app
    let path: String
    var body: some View {
        let current = app.store.index(path)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
            ForEach(0..<16, id: \.self) { c in
                Button { app.session.set(path, index: c) } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.isInverted(c) ? Color.black : Theme.channelColor(c))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.channelColor(c), lineWidth: Theme.isInverted(c) ? 3 : 0))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: current == c ? 3 : 0).padding(-3))
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Theme.colorName(c))
                .accessibilityAddTraits(current == c ? .isSelected : [])
            }
        }
    }
}
