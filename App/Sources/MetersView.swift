import SwiftUI
import XAirKit

struct MetersView: View {
    @Environment(AppModel.self) private var app
    var standalone = true
    private var showRTA: Bool { app.showingRTA }

    var body: some View {
        @Bindable var app = app
        ScreenContainer(standalone: standalone) {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("View", selection: $app.showingRTA) {
                        Text("Meters").tag(false)
                        Text("RTA").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if showRTA { RTAView() } else { meterOverview }
                }
                .padding()
            }
            .navigationTitle(showRTA ? "RTA" : "Meters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SessionToolbar() }
            .meterSubscriptions(showRTA ? [4] : [2, 5, 7, 8])
        }
    }

    private var meterOverview: some View {
        let m = app.session.meters
        return VStack(spacing: 16) {
            Card(title: "Channels and returns", systemImage: "chart.bar.fill") {
                MeterRow(labels: (0..<app.model.channelCount).map { String($0 + 1) } + ["AuxL", "AuxR"] + (1...4).flatMap { ["F\($0)L", "F\($0)R"] },
                         values: (0..<app.model.channelCount).map { m.dB(.mixer, $0) } + (16..<26).map { m.dB(.mixer, $0) })
            }
            Card(title: "Buses, sends and main", systemImage: "chart.bar.fill") {
                MeterRow(labels: (1...6).map { "B\($0)" } + (1...4).map { "S\($0)" } + ["L", "R", "Mon L", "Mon R"],
                         values: (26..<40).map { m.dB(.mixer, $0) })
            }
            Card(title: "Inputs and USB", systemImage: "cable.connector") {
                let inputs = (0..<app.model.analogInputCount).map { m.dB(.inputs, $0) }
                MeterRow(labels: (1...app.model.analogInputCount).map { "In\($0)" } + ["AuxL", "AuxR"], values: inputs + [m.dB(.inputs, 16), m.dB(.inputs, 17)])
                if app.model.hasUSBAudioInterface {
                    MeterRow(labels: (1...18).map { "U\($0)" }, values: (18..<36).map { m.dB(.inputs, $0) })
                }
            }
            Card(title: "Output connectors", systemImage: "cable.connector") {
                let aux = app.model.auxOutputCount
                MeterRow(labels: (1...aux).map { "Aux \($0)" } + ["L", "R", "Phones L", "Phones R"],
                         values: (Array(0..<aux) + [6, 7, 42, 43]).map { m.dB(.outputs, $0) })
                if app.model.hasUltranetAndUSBRouting {
                    MeterRow(labels: (1...16).map { "P16·\($0)" }, values: (8..<24).map { m.dB(.outputs, $0) })
                    MeterRow(labels: (1...18).map { "USB·\($0)" }, values: (24..<42).map { m.dB(.outputs, $0) })
                }
            }
            Card(title: "Dynamics gain reduction", systemImage: "gauge.with.dots.needle.33percent") {
                MeterRow(labels: (1...16).map { "Gate \($0)" }, values: (0..<16).map { m.dB(.dynamics, $0) }, reduction: true)
                let strips = Array(0..<16) + Array(21..<27) + [31]
                MeterRow(labels: strips.map { app.stripName($0) }, values: strips.compactMap { MeterBlock.compressorIndex(strip: $0) }.map { m.dB(.dynamics, $0) }, reduction: true)
            }
            Card(title: "Automix gain", systemImage: "waveform") {
                MeterRow(labels: (1...16).map(String.init), values: (0..<16).map { m.dB(.automix, $0) }, reduction: true)
            }
            Card(title: "DCA masters", systemImage: "slider.vertical.3") {
                MeterRow(labels: (32..<36).map { app.stripName($0) }, values: (0..<4).map { m.dB(.dca, $0) })
            }
            if m.packetCount == 0 {
                ContentUnavailableView("Waiting for meter data", systemImage: "waveform.badge.exclamationmark",
                                       description: Text("Meters are subscribed with /batchsubscribe and renewed every 2 seconds."))
            }
        }
    }
}

struct MeterRow: View {
    let labels: [String]
    let values: [Float]
    var reduction = false
    var height: CGFloat = 110

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(zip(labels, values).enumerated()), id: \.offset) { _, lv in
                    VStack(spacing: 4) {
                        if reduction {
                            GeometryReader { geo in
                                let fraction = CGFloat(min(1, max(0, -lv.1 / 30)))
                                ZStack(alignment: .top) {
                                    Capsule().fill(.quaternary)
                                    Rectangle().fill(.orange).frame(height: geo.size.height * fraction)
                                }.clipShape(.capsule)
                            }.frame(width: 12, height: height)
                        } else {
                            MeterBar(dB: lv.1).frame(width: 12, height: height)
                        }
                        Text(lv.0).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(lv.0)
                    .accessibilityValue(lv.1 <= -89 ? "silent" : String(format: "%.0f dB", lv.1))
                }
            }
        }
    }
}

struct RTAView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let bins = app.session.meters.blocks[4]
        VStack(spacing: 16) {
            Card(title: "Real-time analyser", systemImage: "waveform.path.ecg") {
                Canvas { ctx, size in
                    guard !bins.isEmpty else { return }
                    let w = size.width / CGFloat(bins.count)
                    for (i, v) in bins.enumerated() {
                        let db = Float(v) / 256
                        let f = CGFloat(max(0, min(1, (db + 90) / 90)))
                        let r = CGRect(x: CGFloat(i) * w, y: size.height * (1 - f), width: max(1, w - 1), height: size.height * f)
                        ctx.fill(Path(r), with: .color(db > -6 ? Theme.meterRed : db > -18 ? Theme.meterYellow : Theme.meterGreen))
                    }
                }
                .frame(height: 220)
                .background(.black.opacity(0.06), in: .rect(cornerRadius: 12))
                .accessibilityLabel("RTA spectrum, \(bins.count) bands")
                if bins.isEmpty { Text("Waiting for /meters/4…").font(.footnote).foregroundStyle(.secondary) }
                HStack {
                    ParamPicker(path: "/-stat/rta/source", label: "Source", labels: app.store.schema.labels["rtaSource"])
                    ParamPicker(path: "/-stat/rta/pos", label: "Tap", labels: ["Pre", "Post"])
                }
            }
            Card(title: "RTA preferences", systemImage: "slider.horizontal.3") {
                ParamPicker(path: "/-prefs/rta/det", label: "Detector", labels: ["Peak", "RMS"])
                ParamSlider(path: "/-prefs/rta/decay", label: "Decay", unit: "s")
                ParamPicker(path: "/-prefs/rta/peakhold", label: "Peak hold")
            }
        }
    }
}

struct VisibleMeterSubscriptions: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var owner = UUID()
    let blocks: Set<Int>
    func body(content: Content) -> some View {
        content
            .onAppear { app.session.setVisibleMeters(blocks, owner: owner) }
            .onChange(of: blocks) { _, next in app.session.setVisibleMeters(next, owner: owner) }
            .onDisappear { app.session.setVisibleMeters([], owner: owner) }
    }
}

extension View {
    func meterSubscriptions(_ blocks: Set<Int>) -> some View {
        modifier(VisibleMeterSubscriptions(blocks: blocks))
    }
}

struct SelectedLevels: View {
    @Environment(AppModel.self) private var app
    let stereo: Bool
    var keyIndex: Int?
    var reductionIndex: Int?
    var body: some View {
        let m = app.session.meters
        Card(title: "Signal levels", systemImage: "waveform") {
            if m.raw(.selectedChannel, 0) != nil {
                let labels = stereo ? ["In L", "In R", "Out L", "Out R"] : ["Input", "Output"]
                let indices = stereo ? [0, 1, 4, 5] : [0, 4]
                HStack(alignment: .top) {
                    MeterRow(labels: labels + (keyIndex == nil ? [] : ["Key"]),
                             values: (indices + [keyIndex].compactMap { $0 }).map { m.dB(.selectedChannel, $0) }, height: 60)
                    if let reductionIndex {
                        MeterRow(labels: ["Reduction"], values: [m.dB(.selectedChannel, reductionIndex)], reduction: true, height: 60)
                    }
                }
            } else { Text("Waiting for channel meters").foregroundStyle(.secondary) }
        }
    }
}
