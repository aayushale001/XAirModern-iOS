import SwiftUI
import XAirKit

struct EQSection: View {
    @Environment(AppModel.self) private var app
    let base: String
    let strip: Int
    @State private var band = 1
    @State private var rtaOverlay = false
    @State private var confirmReset = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var bandCount: Int { app.store.isNode(base + "/eq/6") ? 6 : 4 }
    var hasModes: Bool { app.store.spec(base + "/eq/mode") != nil }

    var body: some View {
        let mode = hasModes ? app.store.index(base + "/eq/mode") : 0
        VStack(spacing: 16) {
            Card(title: "Equalizer", systemImage: "slider.horizontal.below.square.and.square.filled") {
                let controlLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                controlLayout {
                    ParamToggle(path: base + "/eq/on", label: "EQ on")
                    if hasModes { ParamPicker(path: base + "/eq/mode", label: "Mode") }
                    Toggle("RTA", isOn: $rtaOverlay).fixedSize()
                    if mode == 0 {
                        Button("Reset EQ") {
                            if app.confirmPopups { confirmReset = true } else { resetEQ() }
                        }.buttonStyle(.bordered)
                    }
                }
                if mode == 0 {
                    EQGraph(base: base, bands: bandCount, selected: $band, showRTA: rtaOverlay)
                        .frame(height: 220)
                    ChipPicker(items: Array(1...bandCount), title: bandName, selection: $band)
                        .accessibilityLabel("EQ band")
                    let p = base + "/eq/\(band)"
                    ParamPicker(path: p + "/type", label: "Band type", labels: ["Low cut", "Low shelf", "PEQ", "Vintage EQ", "High shelf", "High cut"])
                        .fixedSize()
                    let knobLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 16))
                    knobLayout {
                        ParamKnob(path: p + "/f", label: "Freq", unit: "Hz", size: 60)
                        ParamKnob(path: p + "/g", label: "Gain", unit: "dB", size: 60)
                        ParamKnob(path: p + "/q", label: "Q", size: 60)
                    }
                } else {
                    GEQEditor(base: base + "/geq")
                }
            }
        }
        .meterSubscriptions(rtaOverlay ? [4] : [])
        .onChange(of: rtaOverlay, initial: true) { if rtaOverlay { setRTASource() } }
        .onChange(of: strip) {
            band = min(band, bandCount)
            if rtaOverlay { setRTASource() }
        }
        .confirmationDialog("Reset all EQ bands?", isPresented: $confirmReset) {
            Button("Reset EQ", role: .destructive) { resetEQ() }
        }
    }

    private func bandName(_ b: Int) -> String {
        let labels = app.store.schema.labels["eqBandButtons"] ?? []
        if bandCount == 4 { return ["Low", "LoMid", "HiMid", "High"][b - 1] }
        return b - 1 < labels.count ? labels[b - 1] : "\(b)"
    }

    /// RTA over EQ: select this strip as RTA source (/-stat/rta/source) and subscribe /meters/4.
    private func setRTASource() {
        if (0..<32).contains(strip) { app.session.set("/-stat/rta/source", index: strip) }
    }

    private func resetEQ() {
        app.session.pushNodes(SceneFiles.resetEQ(store: app.store, channel: base))
    }

}

struct EQGraph: View {
    @Environment(AppModel.self) private var app
    let base: String
    let bands: Int
    @Binding var selected: Int
    var showRTA = false

    @ScaledMetric(relativeTo: .body) private var handleSize: CGFloat = 32
    private let minF = 20.0, maxF = 20000.0, range = 18.0

    var body: some View {
        let on = app.store.bool(base + "/eq/on")
        let specs = (1...bands).map { band(for: $0) }
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Canvas { ctx, size in
                    // grid
                    for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                        let x = xFor(f, w: size.width)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                    }
                    for g in [-12.0, -6, 0, 6, 12] {
                        let y = yFor(g, h: size.height)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(.secondary.opacity(g == 0 ? 0.45 : 0.18)), lineWidth: 1)
                    }
                    if showRTA {
                        let bins = app.session.meters.blocks[4]
                        if !bins.isEmpty {
                            let bw = size.width / CGFloat(bins.count)
                            for (i, v) in bins.enumerated() {
                                let db = Double(v) / 256
                                let frac = max(0, min(1, (db + 80) / 80))
                                let r = CGRect(x: CGFloat(i) * bw, y: size.height * (1 - frac), width: bw - 1, height: size.height * frac)
                                ctx.fill(Path(r), with: .color(.teal.opacity(0.25)))
                            }
                        }
                    }
                    // response
                    var path = Path()
                    let n = 160
                    for i in 0...n {
                        let f = minF * pow(maxF / minF, Double(i) / Double(n))
                        let g = on ? specs.reduce(0) { $0 + $1.response(at: f) } : 0
                        let pt = CGPoint(x: xFor(f, w: size.width), y: yFor(g, h: size.height))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(on ? .accentColor : .secondary), lineWidth: 2.5)
                }
                ForEach(1...bands, id: \.self) { b in
                    let s = specs[b - 1]
                    Button { selected = b } label: {
                        Text("\(b)")
                            .font(.body.bold())
                            .foregroundStyle(.white)
                            .frame(width: handleSize, height: handleSize)
                            .background(b == selected ? Color.accentColor : Color.secondary, in: .circle)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("EQ band \(b)")
                    .accessibilityValue("\(app.store.display(base + "/eq/\(b)/f")) Hz, \(app.store.display(base + "/eq/\(b)/g")) dB")
                    .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("EQ plot"))
                        .onChanged { v in
                            guard w > 0, h > 0 else { return }
                            selected = b
                            let f = minF * pow(maxF / minF, Double(max(0, min(w, v.location.x)) / w))
                            app.session.set(base + "/eq/\(b)/f", value: Float(f))
                            if s.hasGain {
                                let g = (0.5 - Double(v.location.y / h)) * 2 * range
                                app.session.set(base + "/eq/\(b)/g", value: Float(max(-15, min(15, g))))
                            }
                        })
                    .position(x: xFor(s.f, w: w), y: yFor(s.hasGain ? s.g : 0, h: h))
                }
            }
        }
        .coordinateSpace(name: "EQ plot")
        .background(.black.opacity(0.04), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("EQ curve")
    }

    private func band(for b: Int) -> EQBandShape {
        let p = base + "/eq/\(b)"
        return EQBandShape(type: app.store.index(p + "/type"),
                           f: Double(app.store.physical(p + "/f")),
                           g: Double(app.store.physical(p + "/g")),
                           q: Double(app.store.physical(p + "/q")))
    }

    private func xFor(_ f: Double, w: CGFloat) -> CGFloat { w * CGFloat(log(f / minF) / log(maxF / minF)) }
    private func yFor(_ g: Double, h: CGFloat) -> CGFloat { h * CGFloat(0.5 - g / (2 * range)) }
}

/// Display-only magnitude response (RBJ biquad cookbook); the mixer's DSP is not modelled exactly.
struct EQBandShape {
    let type: Int  // 0 LCut, 1 LShv, 2 PEQ, 3 VEQ, 4 HShv, 5 HCut
    let f, g, q: Double
    var hasGain: Bool { type != 0 && type != 5 }

    func response(at freq: Double) -> Double {
        let fs = 48000.0
        let w0 = 2 * Double.pi * f / fs
        let A = pow(10, g / 40)
        let alpha = sin(w0) / (2 * max(q, 0.1))
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        let c = cos(w0)
        switch type {
        case 0: // high-pass (low cut)
            b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case 5: // low-pass (high cut)
            b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case 1:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * c + s); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - s)
            a0 = (A + 1) + (A - 1) * c + s; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - s
        case 4:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * c + s); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - s)
            a0 = (A + 1) - (A - 1) * c + s; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - s
        default: // PEQ / VEQ
            b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A
        }
        let w = 2 * Double.pi * freq / fs
        let cw = cos(w), c2w = cos(2 * w), sw = sin(w), s2w = sin(2 * w)
        let numR = b0 + b1 * cw + b2 * c2w, numI = -(b1 * sw + b2 * s2w)
        let denR = a0 + a1 * cw + a2 * c2w, denI = -(a1 * sw + a2 * s2w)
        let mag = sqrt((numR * numR + numI * numI) / max(denR * denR + denI * denI, 1e-12))
        return 20 * log10(max(mag, 1e-6))
    }
}

/// 31-band graphic EQ editor for bus / main GEQ and TEQ modes.
struct GEQEditor: View {
    @Environment(AppModel.self) private var app
    let base: String

    var body: some View {
        let bands = app.store.schema.nodes[base]?.params.map(\.name) ?? []
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(bands, id: \.self) { b in
                    VStack(spacing: 4) {
                        Text(app.store.display(base + "/" + b)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        GEQSlider(path: base + "/" + b, label: "\(b) Hz")
                            .frame(width: 26, height: 180)
                        Text(b).font(.caption2).rotationEffect(.degrees(-60)).fixedSize().frame(height: 26)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct GEQSlider: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    @State private var start: Int?
    var body: some View {
        let spec = app.store.spec(path)
        let steps = spec?.maxIndex ?? 60
        let idx = app.store.value(path)?.index ?? steps / 2
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                Capsule().fill(.quaternary).frame(width: 4)
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 14, height: 1).position(x: geo.size.width / 2, y: h / 2)
                Capsule().fill(Color.accentColor).frame(width: 22, height: 12)
                    .position(x: geo.size.width / 2, y: h * (1 - CGFloat(idx) / CGFloat(max(steps, 1))))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if start == nil { start = idx }
                    app.session.set(path, index: (start ?? idx) + Int((-g.translation.height / h * CGFloat(steps)).rounded()))
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { app.session.set(path, value: 0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(app.store.display(path) + " dB")
        .accessibilityAdjustableAction { d in app.session.set(path, index: idx + (d == .increment ? 1 : -1)) }
    }
}

/// Static transfer curve for gate/expander and compressor (display only).
struct DynamicsGraph: View {
    @Environment(AppModel.self) private var app
    let base: String
    let isGate: Bool

    var body: some View {
        let thr = Double(app.store.physical(base + "/thr"))
        let on = app.store.bool(base + "/on")
        let ratioText = isGate ? "" : app.store.display(base + "/ratio")
        let ratio = Double(ratioText) ?? 3
        let range = isGate ? Double(app.store.physical(base + "/range")) : 0
        let knee = isGate ? 0 : Double(app.store.physical(base + "/knee")) * 2
        Canvas { ctx, size in
            let minDB = -80.0
            func pt(_ inDB: Double, _ outDB: Double) -> CGPoint {
                CGPoint(x: size.width * CGFloat((inDB - minDB) / -minDB), y: size.height * CGFloat(1 - (outDB - minDB) / -minDB))
            }
            ctx.stroke(Path { $0.move(to: pt(minDB, minDB)); $0.addLine(to: pt(0, 0)) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            var p = Path()
            for i in 0...120 {
                let x = minDB + Double(i) / 120 * -minDB
                var y = x
                if isGate {
                    if x < thr { y = max(x - range, minDB) }
                } else if x > thr - knee / 2 {
                    let over = x - thr
                    if knee > 0 && abs(over) < knee / 2 {
                        y = x + (1 / ratio - 1) * pow(over + knee / 2, 2) / (2 * knee)
                    } else if over > 0 { y = thr + over / ratio }
                }
                let q = pt(x, y)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            ctx.stroke(p, with: .color(on ? .accentColor : .secondary), lineWidth: 2.5)
            let tp = pt(thr, thr)
            ctx.fill(Path(ellipseIn: CGRect(x: tp.x - 4, y: tp.y - 4, width: 8, height: 8)), with: .color(.orange))
        }
        .background(.black.opacity(0.04), in: .rect(cornerRadius: 12))
        .accessibilityLabel(isGate ? "Gate transfer curve" : "Compressor transfer curve")
        .accessibilityValue("Threshold \(app.store.display(base + "/thr")) dB")
    }
}
