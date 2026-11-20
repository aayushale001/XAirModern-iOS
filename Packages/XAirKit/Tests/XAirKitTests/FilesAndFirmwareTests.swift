import Foundation
import Testing
@testable import XAirKit

@Suite("Scene, preset and firmware files")
@MainActor
struct FilesAndFirmwareTests {
    @Test func sceneExportImportRoundTrip() throws {
        let a = ParameterStore()
        a.applyNodeText("ch/02/config \"Bass\" 3 In02 U02")
        a.applyNodeText("ch/02/eq/1 PEQ 1k97 +3.50 2.0")
        let text = SceneFiles.exportScene(store: a)
        #expect(text.split(separator: "\n").count == 693)
        let b = ParameterStore()
        let msgs = SceneFiles.importLines(text, into: b)
        #expect(msgs.count == 693)
        #expect(b.string("/ch/02/config/name") == "Bass")
        #expect(b.index("/ch/02/config/color") == 3)
        #expect(b.display("/ch/02/eq/1/f") == "1k97")
        #expect(b.display("/ch/02/eq/1/g") == "+3.50")
    }

    @Test func channelPresetRewritesTargetChannel() {
        let s = ParameterStore()
        s.applyNodeText("ch/01/gate ON GATE -40.0 30.0 5 10.0 200 SELF")
        let preset = SceneFiles.exportChannelPreset(store: s, channel: "/ch/01", scope: .gate)
        #expect(preset.contains("gate ON GATE"))
        let msgs = SceneFiles.importChannelPreset(preset, into: s, channel: "/ch/07")
        #expect(msgs.map(\.address) == ["/ch/07/gate", "/ch/07/gate/filter"])
        #expect(s.bool("/ch/07/gate/on"))
        #expect(s.display("/ch/07/gate/thr") == "-40.0")
    }

    @Test func fxPresetLoadsIntoOtherSlot() throws {
        let s = ParameterStore()
        let dly = try #require(s.schema.fxTypes.firstIndex(of: "DLY"))
        s.store("/fx/1/type", index: dly)
        s.store("/fx/1/par/02", index: 1000)
        let text = SceneFiles.exportFXPreset(store: s, slot: 1)
        let msgs = SceneFiles.importFXPreset(text, into: s, slot: 3)
        #expect(s.fxTypeName(slot: 3) == "DLY")
        #expect(s.index("/fx/3/par/02") == 1000)
        #expect(msgs.map(\.address).contains("/fx/3/par"))
    }

    @Test func pasteRespectsScope() {
        let s = ParameterStore()
        s.applyNodeText("ch/01/config \"Kick\" 1 In01 U01")
        s.applyNodeText("ch/01/eq/2 PEQ 100.0 -6.00 1.0")
        let clip = SceneFiles.copyChannel(store: s, channel: "/ch/01")
        _ = SceneFiles.paste(clip, into: s, channel: "/ch/04", scopes: [.eq])
        #expect(s.display("/ch/04/eq/2/g") == "-6.00")
        #expect(s.string("/ch/04/config/name") == "")
    }

    @Test func snapshotScopeString() {
        var sc = SnapshotScope(string: "+-+")
        #expect(sc.flags.count == 59 && sc.flags[0] && !sc.flags[1] && sc.flags[2] && !sc.flags[58])
        sc = SnapshotScope(all: false)
        #expect(!sc.isValid)
        #expect(SnapshotScope(all: true).string.count == 59)
    }

    @Test func firmwareFileRules() {
        #expect(FirmwareFileCheck.validate(fileName: "XR18_1_22.update", size: 100, hardwareIsV2: false) == .success(.init(isV2File: false)))
        #expect(FirmwareFileCheck.validate(fileName: "XR18_V2_1_22.update", size: 100, hardwareIsV2: false) == .failure(.wrongHardwareGeneration(needsV2File: false)))
        #expect(FirmwareFileCheck.validate(fileName: "XR18_1_22.update", size: 100, hardwareIsV2: true) == .failure(.wrongHardwareGeneration(needsV2File: true)))
        #expect(FirmwareFileCheck.validate(fileName: "XR18.bin", size: 100, hardwareIsV2: false) == .failure(.notAnUpdateFile))
    }

    @Test func firmwarePacketsReuseBuffer() {
        var d = Data(repeating: 0xAA, count: 1024)
        d.append(Data(repeating: 0xBB, count: 10))
        let p = FirmwareUpdater.packets(for: d)
        #expect(p.count == 2 && p.allSatisfy { $0.count == 1032 })
        #expect([UInt8](p[1][0..<8]) == Array("sW**".utf8) + [0, 4, 0, 0])
        #expect(p[1][8] == 0xBB && p[1][8 + 10] == 0xAA) // stale tail from the previous chunk
    }

    @Test func firmwareUpdaterAgainstFakeDevice() async throws {
        let link = LoopbackLink(mixerPort: 10018)
        let device = link.mixerEndpoint
        final class Log: @unchecked Sendable { var heads: [String] = []; let l = NSLock() }
        let log = Log()
        try device.start { dg in
            let head = String(decoding: dg.data.prefix(4), as: UTF8.self)
            log.l.withLock { log.heads.append(head) }
            try? device.send(Data("Y".utf8), to: dg.host, port: dg.port)
        }
        let updater = FirmwareUpdater(transport: link.clientEndpoint, host: link.mixerHost)
        let fw = Data(repeating: 0x5A, count: 12 * 1024 + 7)
        await #expect(throws: FirmwareError.notAuthorized) { try await updater.run(firmware: fw, authorized: false) { _ in } }
        try await updater.run(firmware: fw, authorized: true) { _ in }
        let heads = log.l.withLock { log.heads }
        #expect(heads.first == "us**")
        #expect(heads.filter { $0 == "sW**" }.count == 13)
        #expect(heads.suffix(2) == ["sUpd", "ur**"])
    }
}
