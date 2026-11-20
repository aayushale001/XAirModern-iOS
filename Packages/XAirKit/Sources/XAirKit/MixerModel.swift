import Foundation

/// Mixer families as the original maps them into `_Xmdl` (ConnectPage::checkAndConnectDevice).
public enum MixerModel: Int, CaseIterable, Sendable, Codable {
    case x18 = 0
    case xr18 = 1
    case xr16 = 2
    case xr12 = 3

    /// Maps the `/xinfo` / `/status` model string. Unknown strings return nil.
    public init?(modelString raw: String) {
        switch raw.uppercased() {
        case "X18", "X18V2": self = .x18
        case "XR18", "XR18V2", "MR18", "MR18V2": self = .xr18
        case "XR16", "XR16W": self = .xr16
        case "XR12", "XR12W", "MR12", "MR12W": self = .xr12
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .x18: "X18"
        case .xr18: "XR18"
        case .xr16: "XR16"
        case .xr12: "XR12"
        }
    }

    // MARK: Capabilities (evidence in FEATURE_PARITY.md "Model rules")

    /// All families have 16 mono DSP strips. XR12 channels 13–16 can split a physical input.
    public var channelCount: Int { 16 }
    public var analogInputCount: Int { self == .xr12 ? 12 : 16 }

    public var inputSourceIndices: [Int] { Array(0..<analogInputCount) + [16, 17, 18] }

    /// Inputs with mic preamps (headamp 01..n, gain -12..+60 dB, phantom).
    /// XR16 inputs 9-16 and XR12 inputs 5-12 map to line headamps 17-24 (ChannelInput::setParams).
    public var micPreampCount: Int {
        switch self {
        case .x18, .xr18: 16
        case .xr16: 8
        case .xr12: 4
        }
    }

    /// Physical aux outputs; higher buses default to subgroup taps (state_initializeConsole).
    public var auxOutputCount: Int {
        switch self {
        case .x18, .xr18: 6
        case .xr16: 4
        case .xr12: 2
        }
    }

    /// 18x18 USB audio interface (USB returns, USB send routing, clock/USB mode setup).
    public var hasUSBAudioInterface: Bool { self == .x18 || self == .xr18 }

    /// 2-track USB stick recorder (/-stat/tape, /-stat/usb) — sync reads it only on XR16/XR12 (OscCom::run).
    public var hasUSBRecorder: Bool { self == .xr16 || self == .xr12 }

    /// Routing tabs: 6 on X18/XR18, 3 otherwise (RoutingModuleTabbedComponent::buttonClicked).
    public var hasUltranetAndUSBRouting: Bool { hasUSBAudioInterface }

    /// Number of /-prefs,/-snap,/-stat paths requested before the main sync (OscCom::run: 0x4f or 0x52).
    public var prefStatSnapCount: Int { rawValue > 1 ? 82 : 79 }

    /// Display labels for /ch/NN/config/insrc values (input_txt / inputXR16_txt / inputXR12_txt).
    public func inputSourceLabel(index: Int, schema: XAirSchema = .shared) -> String {
        let key: String
        switch self {
        case .x18, .xr18: key = "inputX18"
        case .xr16: key = "inputXR16"
        case .xr12: key = "inputXR12"
        }
        let labels = schema.labels[key] ?? []
        guard inputSourceIndices.contains(index) else { return "Off" }
        let index = self == .xr12 && index >= 16 ? index - 4 : index
        return index >= 0 && index < labels.count ? labels[index] : "?"
    }

    /// Headamp feeding a channel whose `insrc` index is `source` (nil = no preamp, e.g. aux on X18/XR18).
    public func headampIndex(forInputSource source: Int) -> Int? {
        guard source >= 0 else { return nil }
        switch self {
        case .x18, .xr18: return source < 16 ? source + 1 : nil
        case .xr16:
            if source < 8 { return source + 1 }
            if source < 16 { return source + 9 }   // insrc 8..15 -> headamp 17..24
            return nil
        case .xr12:
            if source < 4 { return source + 1 }
            if source < 12 { return source + 13 }  // insrc 4..11 -> headamp 17..24
            return nil
        }
    }

    /// Differences from the XR18 factory scene in state_initializeConsole.
    func applyFactoryDifferences(_ set: (String, Int) -> Void) {
        if self == .xr12 {
            for ch in 13...16 { set(String(format: "/ch/%02d/config/insrc", ch), 16) }
        }
        if self != .xr18 {
            for side in 1...2 {
                let route = String(format: "/routing/usb/%02d", side)
                set(route + "/src", 35 + side)
                set(route + "/pos", 4)
            }
        }
        guard auxOutputCount < 6 else { return }
        for bus in (auxOutputCount + 1)...6 {
            set("/bus/\(bus)/mix/lr", 1)
            for strip in 0..<21 {
                let base = SceneFiles.channelBase(strip)
                set(base + String(format: "/mix/%02d/tap", bus), 5)
            }
        }
    }

    /// Whether a headamp has phantom power / mic gain range (01..16 do, 17..24 are line, -12..+20 dB).
    public static func headampIsMic(_ headamp: Int) -> Bool { headamp >= 1 && headamp <= 16 }
}

/// Hardware variant flags set in ConnectPage::setActiveDevice.
public struct MixerHardware: Sendable, Equatable, Codable {
    public let modelString: String
    public var isV2: Bool { ["XR18V2", "MR18V2", "X18V2"].contains(modelString.uppercased()) }
    public var hasAlternateWiFi: Bool { isV2 || ["XR12W", "XR16W", "MR12W"].contains(modelString.uppercased()) }
    public init(modelString: String) { self.modelString = modelString }
}

/// Information from a `/xinfo` reply.
public struct MixerDevice: Sendable, Equatable, Hashable, Identifiable, Codable {
    public var ip: String
    public var name: String
    public var modelString: String
    public var firmware: String
    public var id: String { ip }

    public init(ip: String, name: String, modelString: String, firmware: String) {
        self.ip = ip
        self.name = name
        self.modelString = modelString
        self.firmware = firmware
    }

    public var model: MixerModel? { MixerModel(modelString: modelString) }

    /// The character-position rule in ConnectPage::checkAndConnectDevice:
    /// fw[0] > '0', fw[2] >= '0', and (fw[2] != '0' || fw[3] > '8').  ("1.09" and later.)
    public static func isFirmwareCompatible(_ fw: String) -> Bool {
        let b = Array(fw.utf8)
        guard b.count >= 4 else { return false }
        let zero = UInt8(ascii: "0"), eight = UInt8(ascii: "8")
        return b[0] > zero && b[2] >= zero && (b[2] != zero || b[3] > eight)
    }

    public var isFirmwareCompatible: Bool { Self.isFirmwareCompatible(firmware) }
}
