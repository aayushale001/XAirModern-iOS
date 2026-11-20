import Foundation
import Testing
@testable import XAirKit

@Suite("OSC codec")
struct OSCCodecTests {
    @Test func roundTripAllTypes() throws {
        let m = OSCMessage("/ch/01/config", [.string("Kick"), .int(3), .float(0.75), .blob(Data([1, 2, 3, 4, 5]))])
        let d = OSCCodec.encode(m)
        #expect(d.count % 4 == 0)
        #expect(try OSCCodec.decode(d) == m)
    }

    @Test func noArgumentRequestMatchesOscpackLayout() {
        // send_text("/status"): BeginMessage + MessageTerminator -> address + ","
        let d = OSCCodec.encode(OSCMessage("/status"))
        #expect([UInt8](d) == Array("/status".utf8) + [0] + Array(",".utf8) + [0, 0, 0])
    }

    @Test func stringPaddingIsFourByteAligned() {
        #expect(OSCCodec.encode(OSCMessage("/abc")).count == 8 + 4)   // "/abc\0\0\0\0" + ",\0\0\0"
        #expect(OSCCodec.encode(OSCMessage("/abcd")).count == 8 + 4)
    }

    @Test func boundedParsingRejectsBadPackets() {
        #expect(throws: OSCError.misaligned(6)) { try OSCCodec.decode(Data("/xinfo".utf8)) }
        #expect(throws: OSCError.packetTooLarge(1504)) { try OSCCodec.decode(Data(count: 1504)) }
        var truncated = OSCCodec.encode(OSCMessage("/x", [.int(1)]))
        truncated.removeLast(4)
        #expect(throws: (any Error).self) { try OSCCodec.decode(truncated) }
        let badBlob = OSCCodec.encode(OSCMessage("/x", [.int(9999)])).replacingTag("i", with: "b")
        #expect(throws: (any Error).self) { try OSCCodec.decode(badBlob) }
        #expect(throws: OSCError.bundlesNotSupported) { try OSCCodec.decode(OSCCodec.encode(OSCMessage("#bundle"))) }
    }

    @Test func discoveryProbeIsSixRawBytes() {
        // osc::OscCom::broadcastDevice writes 6 bytes "/xinfo" with no terminator/padding.
        #expect(Array("/xinfo".utf8) == [0x2f, 0x78, 0x69, 0x6e, 0x66, 0x6f])
    }

    @Test func meterBlobDecoding() {
        let values: [Int16] = (0..<40).map { Int16($0 * -256) }
        let blob = MeterDecoder.encode(values: values)
        #expect(blob.count == 4 + 80)
        #expect(MeterDecoder.decode(blob: blob, expectedCount: 40) == values)
        #expect(MeterDecoder.decode(blob: blob, expectedCount: 36) == nil)
        #expect(MeterDecoder.decode(blob: blob.dropLast(2), expectedCount: nil) == nil)
        #expect(MeterDecoder.blockIndex(address: "meters/1") == 1)
        #expect(MeterDecoder.dB(-2560) == -10)
    }
}

extension Data {
    func replacingTag(_ a: Character, with b: Character) -> Data {
        var bytes = [UInt8](self)
        if let i = bytes.firstIndex(of: UInt8(ascii: ",")), bytes[i + 1] == a.asciiValue! { bytes[i + 1] = b.asciiValue! }
        return Data(bytes)
    }
}

@Suite("Schema and value law")
struct SchemaTests {
    let schema = XAirSchema.shared

    @Test func schemaShape() {
        #expect(schema.nodes.count == 1059)
        #expect(schema.syncPaths.count == 693)
        #expect(schema.prefStatSnapPaths.count == 82)
        #expect(schema.meterBatchSize == [8, 40, 36, 56, 100, 44, 39, 16, 4, 4])
        #expect(schema.fxTypes.count == 61)
        #expect(schema.meterIds[1] == "meters/1" && schema.meterPaths[1] == "/meters/1")
        #expect(schema.nodes["/ch/16/mix/10"] != nil)
        #expect(schema.nodes["/headamp/24"] != nil)
    }

    @Test func faderSpec() throws {
        let f = try #require(schema.leaf("/ch/01/mix/fader")?.spec)
        #expect(f.kind == .fader(steps: 1023))
        #expect(ParamSpec.levelDB(index: 0, steps: 1023) == -144)
        #expect(abs(f.value(forIndex: 767)) < 0.01)
        #expect(abs(f.value(forIndex: 1023) - 10) < 0.001)
        #expect(f.index(forValue: 0) == 767)
        #expect(f.index(forValue: -90) == 0)
        #expect(ValueText.text(spec: f, index: 0) == "  -oo")
        #expect(ValueText.text(spec: f, index: 767) == "  0.0")
    }

    @Test func logAndLinearRanges() throws {
        let eqf = try #require(schema.leaf("/ch/01/eq/1/f")?.spec)
        #expect(abs(eqf.value(forIndex: 0) - 20) < 0.001)
        #expect(abs(eqf.value(forIndex: 200) - 20000) < 1)
        let q = try #require(schema.leaf("/ch/01/eq/1/q")?.spec)
        #expect(abs(q.value(forIndex: 0) - 10) < 0.001 && abs(q.value(forIndex: 71) - 0.3) < 0.01)
        let gain = try #require(schema.leaf("/headamp/01/gain")?.spec)
        #expect(gain.value(forIndex: 0) == -12 && gain.value(forIndex: 144) == 60)
        let line = try #require(schema.leaf("/headamp/17/gain")?.spec)
        #expect(line.value(forIndex: 64) == 20)
        #expect(try #require(schema.leaf("/ch/01/preamp/hpf")?.spec).value(forIndex: 100) > 399)
    }

    /// For every numeric parameter: OSC float out -> OSC float in reproduces the index,
    /// and getFloat -> setFloat reproduces the index (the original's quantization is lossless).
    @Test func wireAndValueRoundTripIsExactForEveryIndex() {
        var checked = 0
        var seen = Set<String>()
        for path in schema.nodeOrder {
            for p in schema.nodes[path]!.params where !p.isString {
                let key = "\(p.kind)"
                guard seen.insert(key).inserted else { continue }
                for i in p.minIndex...p.maxIndex {
                    let arg = p.oscArgument(index: i, string: "")
                    #expect(p.index(from: arg) == i, "wire \(path)/\(p.name) \(i)")
                    if case .enumeration = p.kind { continue }
                    if case .int = p.kind { continue }
                    let v = p.value(forIndex: i)
                    #expect(p.index(forValue: v) == i, "value \(path)/\(p.name) \(i) \(v)")
                    checked += 1
                }
            }
        }
        #expect(checked > 1000)
    }

    @Test func fxParametersRetypePerEffect() throws {
        let hall = try #require(schema.fxParams["HALL"])
        #expect(hall.count == 12 && hall[0].label == "PreDelay" && hall[1].label == "Decay")
        #expect(try #require(schema.fxParams["GEQ2"]).count == 64)
        let dly = try #require(schema.fxParams["DLY"])
        #expect(dly[2].enumItems == ["ST", "X", "M"])
        #expect(schema.fxLongNames[0] == "Hall Reverb")
    }
}

@Suite("Scene text format (golden vs. the original app's own output)")
struct TextFormatTests {
    @Test func printfPort() {
        #expect(XAirPrintf.format("%k1f", 124.7) == "124.7")
        #expect(XAirPrintf.format("%k1f", 1970) == "1k97")
        #expect(XAirPrintf.format("%k1f", 10020) == "10k02")
        #expect(XAirPrintf.format("%.0kf", 7200) == "7k2")
        #expect(XAirPrintf.format("%3f", 20) == " 20")
        #expect(XAirPrintf.format("%+5.2f", 0) == "+0.00")
        #expect(XAirPrintf.format("%%%04b", 5) == "%0101")
        #expect(XAirPrintf.format("%+f", 0) == "+0")
        #expect(XAirPrintf.format("%f", -20) == "-20")
    }

    @Test func parser() {
        #expect(ValueText.parseNumber("1k97") == 1970)
        #expect(ValueText.parseNumber("10k02").map { abs($0 - 10020) < 0.01 } == true)
        #expect(ValueText.parseInteger("%0101") == 5)
        #expect(ValueText.parseInteger("-3") == -3)
    }

    /// Every line of the default state file written by X-AIR-Edit itself must
    /// round-trip byte-for-byte through our parser and printf port.
    @Test func defaultSceneRoundTripsExactly() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/default", withExtension: "init"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("-localprefs") }
        #expect(lines.count == 693)
        var table = ValueTable()
        var mismatches: [String] = []
        for line in lines {
            table.apply(text: line)
            let path = "/" + String(line.prefix { $0 != " " })
            var out = table.text(for: path) ?? ""
            if path.hasSuffix("/par") {
                // the original pads FX parameter lists with "0" up to 64 entries
                var toks = out.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                while toks.count < 65 { toks.append("0") }
                out = toks.joined(separator: " ")
            }
            if out != line { mismatches.append("\(line)\n   ours: \(out)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.first ?? "")")
    }
}

@Suite("Models and discovery")
struct ModelTests {
    @Test func modelStrings() {
        #expect(MixerModel(modelString: "XR18V2") == .xr18)
        #expect(MixerModel(modelString: "MR12W") == .xr12)
        #expect(MixerModel(modelString: "X18V2") == .x18)
        #expect(MixerModel(modelString: "X32") == nil)
        #expect(MixerHardware(modelString: "XR16W").hasAlternateWiFi)
        #expect(MixerHardware(modelString: "MR18V2").isV2)
    }

    @Test func firmwareRuleFromCheckAndConnectDevice() {
        #expect(MixerDevice.isFirmwareCompatible("1.09"))
        #expect(MixerDevice.isFirmwareCompatible("1.22"))
        #expect(!MixerDevice.isFirmwareCompatible("1.08"))
        #expect(!MixerDevice.isFirmwareCompatible("0.99"))
        #expect(!MixerDevice.isFirmwareCompatible(""))
    }

    @Test func capabilities() {
        #expect(MixerModel.xr12.channelCount == 16 && MixerModel.xr12.analogInputCount == 12)
        #expect(MixerModel.xr16.micPreampCount == 8)
        #expect(MixerModel.xr18.hasUSBAudioInterface && !MixerModel.xr18.hasUSBRecorder)
        #expect(MixerModel.xr12.hasUSBRecorder && !MixerModel.xr12.hasUltranetAndUSBRouting)
        #expect(MixerModel.xr18.prefStatSnapCount == 79 && MixerModel.xr16.prefStatSnapCount == 82)
        #expect(MixerModel.xr16.headampIndex(forInputSource: 8) == 17)
        #expect(MixerModel.xr12.headampIndex(forInputSource: 4) == 17)
        #expect(MixerModel.xr18.headampIndex(forInputSource: 16) == nil)
        #expect(MixerModel.xr18.inputSourceLabel(index: 16) == "17")
        #expect(MixerModel.xr16.inputSourceLabel(index: 16) == "L")
        #expect(MixerModel.xr12.inputSourceLabel(index: 16) == "L")
    }

    @Test func discoveryTargetsOrder() {
        let t = NetworkInterfaces.discoveryTargets()
        #expect(t.first == "192.168.1.1")
        #expect(t.last == "255.255.255.255")
        #expect(t.count <= 7)
        #expect(!t.contains { $0.hasPrefix("127.0.0.1") })
    }
}
