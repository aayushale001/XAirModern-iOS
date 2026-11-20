import SwiftUI
import XAirKit

// Schema-driven controls. Every control reads the observed ParamValue for its path
// and writes through MixerSession.set, which sends OSC and schedules read-back.

struct ParamToggle: View {
    @Environment(AppModel.self) private var app
    let path: String
    var label: String
    var systemImage: String?
    var tint: Color = .accentColor
    /// For mute buttons: the parameter is "on" (1 = unmuted), the button shows "muted".
    var inverted = false
    var compact = false

    var body: some View {
        let v = app.store.value(path)
        let isOn = ((v?.index ?? 0) != 0) != inverted
        Button {
            app.session.toggle(path)
        } label: {
            Group {
                if let systemImage {
                    Label(label, systemImage: systemImage)
                } else {
                    Text(label)
                }
            }
            .font(.body.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: compact ? 26 : 34)
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .tint(isOn ? tint : .secondary)
        .background(isOn ? tint.opacity(0.28) : .clear, in: .capsule)
        .accessibilityLabel(label)
        .accessibilityIdentifier(path)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .disabled(v == nil)
    }
}

/// Menu picker over an enum parameter. `labels` overrides the protocol tokens for display.
struct ParamPicker: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    var labels: [String]? = nil
    var allowed: Range<Int>? = nil
    var indices: [Int]?
    var onSelect: ((Int) -> Void)?

    var body: some View {
        let spec = app.store.spec(path)
        let idx = app.store.value(path)?.index ?? 0
        let items = spec?.enumItems ?? []
        let range = allowed ?? 0..<items.count
        Picker(label, selection: Binding(get: { idx }, set: { value in
            if let onSelect { onSelect(value) } else { app.session.set(path, index: value) }
        })) {
            ForEach(indices ?? Array(range.clamped(to: 0..<max(items.count, 1))), id: \.self) { i in
                Text(display(i, items)).tag(i)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(label)
        .accessibilityValue(display(idx, items))
    }

    private func display(_ i: Int, _ items: [String]) -> String {
        if let labels, i < labels.count { return labels[i] }
        return i < items.count ? items[i] : "\(i)"
    }
}

/// Horizontal slider in index space (log/linear/level laws are exact in index space).
struct ParamSlider: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    var unit: String = ""

    var body: some View {
        let spec = app.store.spec(path)
        let maxI = Double(spec?.maxIndex ?? 1)
        let minI = Double(spec?.minIndex ?? 0)
        let idx = Double(app.store.value(path)?.index ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(app.store.display(path) + (unit.isEmpty ? "" : " \(unit)"))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { idx }, set: { app.session.set(path, index: Int($0.rounded())) }),
                   in: minI...max(maxI, minI + 1), step: 1)
            .accessibilityLabel(label)
            .accessibilityValue(app.store.display(path) + " " + unit)
        }
        .disabled(spec == nil)
    }
}

/// Rotary knob. Vertical drag changes the index; VoiceOver can increment/decrement.
struct ParamKnob: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    var unit: String = ""
    var size: CGFloat = 54
    var tint: Color = .accentColor
    /// Compact console-strip knobs omit visible text (VoiceOver still reads label and value).
    var showsText = true
    @State private var dragStart: Int?
    /// Knobs grow with Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        let spec = app.store.spec(path)
        let maxI = spec?.maxIndex ?? 1
        let minI = spec?.minIndex ?? 0
        let idx = app.store.value(path)?.index ?? 0
        let frac = maxI > minI ? Double(idx - minI) / Double(maxI - minI) : 0
        let size = self.size * scale
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                // Bipolar parameters (pan, gain) draw from the centre.
                let bipolar: Bool = { if case .linear(_, let mn, let mx, _) = spec?.kind { return mn < 0 && mx > 0 }; return false }()
                Circle().trim(from: bipolar ? min(0.375, 0.75 * frac) : 0, to: bipolar ? max(0.375, 0.75 * frac) : 0.75 * frac)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                if showsText {
                    Text(app.store.display(path))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .fixedSize()
                } else {
                    Capsule().fill(tint).frame(width: 3, height: size * 0.3)
                        .offset(y: -size * 0.22)
                        .rotationEffect(.degrees(-135 + 270 * frac))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onTapGesture(count: 2) {
                if let d = spec?.defaultIndex { app.session.set(path, index: d) }
            }
            if showsText {
                Text(label).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: size + 8)
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                if dragStart == nil { dragStart = idx }
                let range = Double(maxI - minI)
                let delta = Int((-g.translation.height / 180.0 * range).rounded())
                app.session.set(path, index: (dragStart ?? idx) + delta)
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(idx) }, set: { app.session.set(path, index: Int($0.rounded())) }),
                   in: Double(minI)...Double(max(minI + 1, maxI)), step: Double(max(1, (maxI - minI) / 50))) {
                Text(label)
            }
            .accessibilityValue(app.store.display(path) + " " + unit)
        }
        .disabled(spec == nil)
    }
}

struct ParamTextField: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let maxLen: Int = { if case .string(let n) = app.store.spec(path)?.kind { return n }; return 16 }()
        let current = app.store.value(path)?.string ?? ""
        TextField(label, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .onAppear { text = current }
            .onChange(of: current) { _, new in if !focused { text = new } }
            .onChange(of: text) { _, new in if new.count > maxLen { text = String(new.prefix(maxLen)) } }
            .onSubmit { app.session.set(path, string: text) }
            .onChange(of: focused) { _, f in if !f && text != current { app.session.set(path, string: text) } }
            .accessibilityLabel(label)
    }
}

struct ParamStepper: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String

    var body: some View {
        let spec = app.store.spec(path)
        let idx = app.store.value(path)?.index ?? 0
        Stepper(value: Binding(get: { idx }, set: { app.session.set(path, index: $0) }),
                in: (spec?.minIndex ?? 0)...(spec?.maxIndex ?? 0)) {
            HStack { Text(label); Spacer(); Text(app.store.display(path)).monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}

/// Bit toggles for `%%%04b`-style parameters (DCA / mute group assignment, MIDI config).
struct BitmaskToggles: View {
    @Environment(AppModel.self) private var app
    let path: String
    let labels: [String]
    var tint: Color = .accentColor

    var body: some View {
        let v = app.store.value(path)?.index ?? 0
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                let on = v & (1 << i) != 0
                Button(l) { app.session.set(path, index: v ^ (1 << i)) }
                    .buttonStyle(.bordered)
                    .tint(on ? tint : .secondary)
                    .background(on ? tint.opacity(0.3) : .clear, in: .capsule)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel(l)
                    .accessibilityValue(on ? "Assigned" : "Not assigned")
            }
        }
    }
}

/// Vertical level fader in index space with a dB scale; double tap = 0 dB.
struct LevelFader: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    let strip: Int
    var tint: Color = .accentColor
    @State private var dragStart: Int?

    private static let marks: [Float] = [10, 5, 0, -10, -20, -30, -50, -90]

    var body: some View {
        let spec = app.store.spec(path)
        let steps = spec?.maxIndex ?? 1023
        let idx = app.store.value(path)?.index ?? 0
        GeometryReader { geo in
            let inset: CGFloat = 14
            let h = geo.size.height - 2 * inset
            let pos = CGFloat(idx) / CGFloat(max(steps, 1))
            ZStack(alignment: .bottom) {
                // scale
                ForEach(Self.marks, id: \.self) { m in
                    let y = inset + h * (1 - CGFloat((spec?.index(forValue: m) ?? 0)) / CGFloat(max(steps, 1)))
                    Rectangle().fill(m == 0 ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.35))
                        .frame(width: m == 0 ? 22 : 14, height: 1)
                        .position(x: geo.size.width / 2, y: y)
                }
                HStack(spacing: 3) {
                    StripMeter(strip: strip, right: false)
                    Capsule().fill(.quaternary).frame(width: 6)
                    StripMeter(strip: strip, right: true)
                }
                .frame(height: h)
                .position(x: geo.size.width / 2, y: inset + h / 2)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint, lineWidth: 2))
                    .overlay(Rectangle().fill(tint).frame(height: 2))
                    .frame(width: min(geo.size.width - 4, 44), height: 26)
                    .shadow(radius: 2, y: 1)
                    .position(x: geo.size.width / 2, y: inset + h * (1 - pos))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = idx }
                    let delta = Int((-g.translation.height / max(app.fineFaders ? geo.size.height * 2 : h, 1) * CGFloat(steps)).rounded())
                    setFader((dragStart ?? idx) + delta)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { if let spec { setFader(spec.index(forValue: 0)) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(app.store.display(path) + " dB")
        .accessibilityAdjustableAction { dir in
            let step = max(1, steps / (app.fineFaders ? 128 : 64))
            setFader(idx + (dir == .increment ? step : -step))
        }
    }
    private func setFader(_ value: Int) {
        guard let spec = app.store.spec(path), spec.clamp(value) != app.store.index(path) else { return }
        if app.selectOnFader { app.selectedStrip = strip }
        app.session.set(path, index: value)
    }
}

struct StripMeter: View {
    @Environment(AppModel.self) private var app
    let strip: Int
    let right: Bool

    var body: some View {
        if let index = meterIndex {
            MeterBar(dB: app.session.meters.dB(strip >= 32 ? .dca : .mixer, index)).frame(width: 6)
        }
    }

    private var meterIndex: Int? {
        switch strip {
        case 0..<16: return right ? nil : strip
        case 16..<21: return 16 + (strip - 16) * 2 + (right ? 1 : 0)
        case 21..<31: return right ? nil : 26 + strip - 21
        case 31: return 36 + (right ? 1 : 0)
        case 32..<36: return right ? nil : strip - 32
        default: return nil
        }
    }
}

struct StripMute: View {
    @Environment(AppModel.self) private var app
    let strip: Int
    var compact = false
    var body: some View {
        let path = AppModel.base(of: strip) + (strip >= 32 ? "/on" : "/mix/on")
        let grouped = app.session.groupMutes(strip: strip)
        let muted = !app.store.bool(path) || grouped
        let lit = app.invertMutes ? !muted : muted
        let tint = app.invertMutes ? Color.green : Theme.mute
        let title = app.invertMutes ? "On" : "Mute"
        Button { app.session.toggle(path) } label: {
            HStack(spacing: 3) {
                if grouped { Image(systemName: "person.2.fill").accessibilityHidden(true) }
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(lit ? tint : .secondary)
        .background(lit ? tint.opacity(0.25) : .clear, in: .capsule)
        .accessibilityLabel(title + " " + app.stripName(strip))
        .accessibilityIdentifier("mute-\(strip)")
        .accessibilityValue(grouped ? "Muted by group" : (muted ? "Muted" : "Unmuted"))
    }
}

/// Peak meter bar. Floor -60 dB, yellow above -12, red above -3 (display choice).
struct MeterBar: View {
    let dB: Float
    var floor: Float = -60
    var horizontal = false

    var body: some View {
        Canvas { ctx, size in
            let f = CGFloat(max(0, min(1, (dB - floor) / (0 - floor))))
            let len = horizontal ? size.width : size.height
            let filled = len * f
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2)
            ctx.fill(bg, with: .color(.secondary.opacity(0.18)))
            let yellowAt = len * CGFloat((-12 - floor) / -floor)
            let redAt = len * CGFloat((-3 - floor) / -floor)
            func seg(_ from: CGFloat, _ to: CGFloat, _ c: Color) {
                guard to > from else { return }
                let r = horizontal ? CGRect(x: from, y: 0, width: to - from, height: size.height)
                                   : CGRect(x: 0, y: size.height - to, width: size.width, height: to - from)
                ctx.fill(Path(r), with: .color(c))
            }
            seg(0, min(filled, yellowAt), Theme.meterGreen)
            seg(yellowAt, min(filled, redAt), Theme.meterYellow)
            seg(redAt, filled, Theme.meterRed)
        }
        .accessibilityHidden(true)
    }
}

/// Section header + content card using system grouped styling.
struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let systemImage { Label(title, systemImage: systemImage).font(.headline) } else { Text(title).font(.headline) }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}
