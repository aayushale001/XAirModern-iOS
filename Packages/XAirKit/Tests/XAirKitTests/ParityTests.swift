import Foundation
import Testing
@testable import XAirKit

@Suite("Desktop parity and mixer read-back", .serialized)
@MainActor
struct ParityTests {
    @Test func allRoutingPresetsReachTheRemoteIncludingCrossTabUSBPlugin() async throws {
        let rig = try Rig()
        defer { rig.session.shutdown(); rig.sim.stop() }
        try await rig.connectAndSync()
        let store = rig.session.store
        let catalog = BuiltinPresets.shared
        for presets in [catalog.ultranet, catalog.usbReturn, catalog.usbSend] {
            #expect(presets.count == 4)
            for preset in presets {
                let writes = SceneFiles.importRouting(preset.lines.joined(separator: "\n"), into: store)
                #expect(!writes.isEmpty)
                let expectedValues = writes.map { ($0.address, store.index($0.address)) }
                rig.session.pushNodes(writes)
                try await rig.until(preset.title) {
                    expectedValues.allSatisfy { rig.sim.value($0.0) == $0.1 && store.index($0.0) == $0.1 }
                }
                for line in preset.lines {
                    let fields = NodeText.tokenize(line)
                    let path = fields[0]
                    let members = store.spec(path).map { [(path, $0)] } ?? store.nodeMembers(path)
                    #expect(members.count == fields.count - 1)
                    for ((leaf, spec), token) in zip(members, fields.dropFirst()) {
                        let expected = try #require(ValueText.parse(spec: spec, token: token))
                        #expect(writes.contains { $0.address == leaf })
                        #expect(rig.sim.value(leaf) == expected.index)
                    }
                }
            }
        }
    }

    @Test func routingRecallFiltersAtLeafGranularityAndHonoursModel() {
        let s = ParameterStore()
        s.loadDefaults()
        let oldColor = s.index("/ch/01/config/color")
        let text = "ch/01/config \"Ignore\" 9 In07 U08\n/ch/01/preamp/rtnsw ON\nrouting/aux/06 Bus2 PRE\n/fx/1/type LIM"
        let writes = SceneFiles.importRouting(text, into: s, scopes: [.inputs])
        #expect(writes.map(\.address) == ["/ch/01/config/insrc"])
        #expect(s.string("/ch/01/config/name").isEmpty && s.index("/ch/01/config/color") == oldColor)
        #expect(!s.bool("/ch/01/preamp/rtnsw") && s.index("/ch/01/config/rtnsrc") == 0)
        let exported = SceneFiles.exportRouting(store: s)
        #expect(exported.contains("ch/01/config/insrc In07") && exported.contains("ch/01/preamp/rtnsw OFF"))
        #expect(!exported.contains("/config/name"))
        let target = ParameterStore()
        #expect(!SceneFiles.importRouting(exported, into: target).isEmpty)
        #expect(target.index("/ch/01/config/insrc") == 6)
        s.setModel(.xr12)
        #expect(SceneFiles.importRouting(text, into: s).map(\.address) == ["/ch/01/config/insrc"])
        #expect(MixerModel.xr12.inputSourceIndices == Array(0..<12) + [16, 17, 18])
    }

    @Test func realDesktopPresetFilesLoadAndExportAcrossSlotsAndChannels() throws {
        let store = ParameterStore()
        func fixture(_ file: String, _ ext: String) throws -> String {
            let url = try #require(Bundle.module.url(forResource: file, withExtension: ext, subdirectory: "Fixtures"))
            return try String(contentsOf: url, encoding: .utf8)
        }
        let fx = try fixture("desktop-hall", "efx")
        store.applyNodeText("fx/4 LIM ON")
        let writes = SceneFiles.importFXPreset(fx, into: store, slot: 4)
        #expect(writes.map(\.address) == ["/fx/4/type", "/fx/4/insert", "/fx/4/par"])
        #expect(SceneFiles.exportFXPreset(store: store, slot: 4) == fx)
        let gate = try fixture("desktop-gate", "gate")
        _ = SceneFiles.importChannelPreset(gate, into: store, channel: "/ch/15")
        #expect(SceneFiles.exportChannelPreset(store: store, channel: "/ch/15", scope: .gate) == gate)
        store.applyNodeText("ch/01/config \"Old\" 4 In03 U09")
        _ = SceneFiles.importChannelPreset("/config/name \"\"\n/config/insrc In07", into: store, channel: "/ch/01")
        #expect(store.string("/ch/01/config/name") == "" && store.index("/ch/01/config/insrc") == 6)
        #expect(store.index("/ch/01/config/color") == 4)
    }

    @Test func eqResetAndPresetConversionKeepTheCorrectBands() {
        let s = ParameterStore()
        s.loadDefaults()
        #expect(SceneFiles.resetEQ(store: s, channel: "/bus/1").count == 6)
        #expect(SceneFiles.resetEQ(store: s, channel: "/ch/01").count == 4)
        s.applyNodeText("ch/01/eq/2 PEQ 500 +6.00 2")
        s.applyNodeText("bus/1/eq/2 PEQ 250 -9.00 2")
        let four = SceneFiles.exportChannelPreset(store: s, channel: "/ch/01", scope: .eq)
        _ = SceneFiles.importChannelPreset(four, into: s, channel: "/bus/1")
        #expect(s.display("/bus/1/eq/3/g") == "+6.00" && s.physical("/bus/1/eq/2/g") == 0)
        let six = SceneFiles.exportChannelPreset(store: s, channel: "/bus/1", scope: .eq)
        _ = SceneFiles.importChannelPreset(six, into: s, channel: "/ch/08")
        #expect(s.display("/ch/08/eq/2/g") == "+6.00")
    }

    @Test func recorderNavigatesRefreshesAndPlaysOnlyFiles() async throws {
        let r = try Rig(model: "XR12")
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        let s = r.session
        let rootEntries = s.recorderEntries
        #expect(rootEntries.map(\.name) == ["SONGS", "R_20261107-120000.wav", "Intro.wav"])
        s.openRecorderEntry(try #require(rootEntries.first))
        try await r.until("folder read") { !s.directoryLoading }
        #expect(s.recorderEntries.map(\.name) == ["Soundcheck.wav", "Archive", "Encore.wav"])
        s.openRecorderEntry(try #require(s.recorderEntries.first))
        try await r.until("file and play") { r.sim.stringValue("/-stat/tape/file") == "/SONGS/Soundcheck.wav" && r.sim.value("/-stat/tape/state") == 2 }
        s.recorderTransport(.pause)
        s.openRecorderEntry(try #require(s.adjacentTrack(forward: true)), play: false)
        try await r.until("skip folder and stay paused") { r.sim.stringValue("/-stat/tape/file") == "/SONGS/Encore.wav" && r.sim.value("/-stat/tape/state") == 1 }
        #expect(s.adjacentTrack(forward: true) == nil && s.adjacentTrack(forward: false)?.name == "Soundcheck.wav")
        let childFolder = s.recorderEntries.first(where: \.isFolder)
        s.openRecorderEntry(try #require(childFolder))
        try await r.until("empty directory") { !s.directoryLoading && s.recorderEntries.isEmpty }
        s.recorderParentDirectory()
        try await r.until("parent") { !s.directoryLoading && s.recorderEntries.count == 3 }
        s.recorderParentDirectory()
        try await r.until("root") { !s.directoryLoading && s.recorderEntries == rootEntries }
        #expect(RecorderAction.play.target(from: 4) == nil && RecorderAction.rewind.target(from: 0) == nil)
        #expect(RecorderAction.record.target(from: 4) == 3 && RecorderAction.pause.target(from: 3) == 4)
    }

    @Test func muteGroupsRespectOverlapsAndHardMuteDisplaysDoNotWriteStripOn() async throws {
        let r = try Rig()
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        let s = r.session, base = "/ch/03"
        s.set("/-prefs/hardmute", index: 0)
        s.set(base + "/grp/mute", index: 3)
        s.set("/config/mute/1", index: 1)
        s.set("/config/mute/2", index: 1)
        s.set("/config/mute/1", index: 0)
        try await r.until("still held") { r.sim.value(base + "/mix/on") == 0 }
        s.set("/config/mute/2", index: 0)
        try await r.until("released") { r.sim.value(base + "/mix/on") == 1 }
        s.set("/-prefs/hardmute", index: 1)
        s.set("/config/mute/1", index: 1)
        #expect(s.groupMutes(strip: 2) && s.store.bool(base + "/mix/on"))
        s.set("/config/mute/1", index: 0)
        s.set("/-prefs/dcamute", index: 1)
        s.set(base + "/grp/dca", index: 4)
        s.set("/dca/3/on", index: 0)
        #expect(s.groupMutes(strip: 2) && !s.groupMutes(strip: 31))
        try await r.until("no write through DCA") { r.sim.value("/dca/3/on") == 0 && r.sim.value(base + "/mix/on") == 1 }
    }

    @Test func linkedTapsOnlyChangeTheChosenDestination() async throws {
        let r = try Rig()
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        let s = r.session
        s.linkSendTaps = true
        s.setSendTap(strip: 16, send: 2, index: 3)
        try await r.until("all 21 sources") { (0..<21).allSatisfy { r.sim.value(SceneFiles.channelBase($0) + "/mix/02/tap") == 3 } }
        let old = s.store.index("/ch/03/mix/03/tap")
        s.linkSendTaps = false
        s.setSendTap(strip: 1, send: 2, index: 2)
        try await r.until("one source") { r.sim.value("/ch/02/mix/02/tap") == 2 }
        #expect(s.store.index("/ch/03/mix/02/tap") == 3 && s.store.index("/ch/03/mix/03/tap") == old)
    }

    @Test func meterDemandsSurviveReconnectAndSharedViews() async throws {
        let r = try Rig(model: "XR16")
        defer { r.session.shutdown(); r.sim.stop() }
        let a = UUID(), b = UUID(), s = r.session
        s.setVisibleMeters([0, 3, 7], owner: a)
        s.setVisibleMeters([3, 9], owner: b)
        try await r.connectAndSync()
        #expect(s.subscribedMeterBlocks == [0, 1, 3, 6, 7, 9])
        s.setVisibleMeters([], owner: a)
        #expect(s.subscribedMeterBlocks == [1, 3, 6, 9])
        s.resync()
        try await r.until("resync") { s.state == .online }
        r.sim.tick()
        try await r.until("recorder meters") { s.meters.blocks[9].count == 4 }
        s.disconnect()
        try await r.connectAndSync()
        #expect(s.subscribedMeterBlocks == [1, 3, 6, 9])
    }

    @Test func effectMetersUseSlotSpecificOffsetsAndAlgorithmUnits() throws {
        let s = ParameterStore(), m = MeterStore()
        var frame = [Int16](repeating: 0, count: 56)
        frame[16] = 128
        frame[17] = 2048
        m.update(block: 3, values: frame)
        #expect(m.effectIndicators(slot: 2, type: "LIM", store: s).map(\.value) == [12, 20])
        #expect(m.effectIndicators(slot: 1, type: "LIM", store: s).map(\.value) == [0, 0])
        #expect(m.effectIndicators(slot: 2, type: "DES2", store: s).count == 4)
        #expect(m.effectIndicators(slot: 2, type: "FAC2", store: s).count == 2)
        #expect(m.effectIndicators(slot: 2, type: "CMB2", store: s).count == 10)
        #expect(MeterBlock.compressorIndex(strip: 15) == 31 && MeterBlock.compressorIndex(strip: 21) == 32 && MeterBlock.compressorIndex(strip: 31) == 38)
        let i = try #require(s.schema.fxTypes.firstIndex(of: "FAC1M"))
        #expect(s.schema.fxLongNames[i] == "M/S Fair Compressor")
    }

    @Test func sidechainSoloSelectsOneChannelBusOrMainKey() async throws {
        let r = try Rig()
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        for (strip, gate, expected) in [(0, true, 1), (15, false, 32), (21, false, 33), (31, false, 39)] {
            let index = try #require(r.session.keySoloIndex(strip: strip, gate: gate))
            #expect(index == expected)
            r.session.set("/-stat/keysolo", index: index)
            try await r.until("solo key") { r.sim.value("/-stat/keysolo") == expected }
        }
        #expect(r.session.keySoloIndex(strip: 17, gate: false) == nil)
    }

    @Test func offlineDefaultsMatchRecorderAndSubgroupModels() {
        let store = ParameterStore()
        for model in [MixerModel.xr12, .xr16, .x18, .xr18] {
            store.setModel(model)
            store.loadDefaults()
            #expect(store.index("/ch/13/config/insrc") == (model == .xr12 ? 16 : 12))
            #expect(store.index("/routing/usb/01/src") == (model == .xr18 ? 0 : 36))
            #expect(store.index("/bus/6/mix/lr") == (model.hasUSBRecorder ? 1 : 0))
            #expect(store.index("/rtn/aux/mix/06/tap") == (model.hasUSBRecorder ? 5 : 2))
        }
    }

    @Test func partialSceneChangesOnlySuppliedMixerParameters() {
        let s = ParameterStore()
        s.loadDefaults()
        let writes = SceneFiles.importLines("/ch/01/config\t\\ 4\n/-prefs/name \"From file\"\n/-action/initall GO\n/ch/03/mix/fader invalid", into: s)
        #expect(writes.map(\.address) == ["/ch/01/config/color"])
        #expect(s.index("/ch/01/config/color") == 4 && s.string("/-prefs/name").isEmpty)
    }

    @Test func snapshotSafesPreserveOtherStripsAndParametersAfterRename() async throws {
        let r = try Rig()
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        let s = r.session
        s.set("/-snap/name", string: "Original")
        s.set("/ch/01/mix/fader", index: 321)
        s.command("/-snap/save", [.int(4)])
        try await r.until("saved with full scope") { r.sim.stringValue("/-snap/04/scope") == SnapshotScope(all: true).string }
        var scope = SnapshotScope(all: false)
        scope.flags[0] = true
        scope.flags[55] = true
        s.set("/-snap/04/scope", string: scope.string)
        s.set("/-snap/04/name", string: "Renamed")
        s.set("/ch/01/mix/fader", index: 126)
        s.set("/ch/02/mix/fader", index: 405)
        s.set("/ch/01/mix/on", index: 0)
        s.command("/-snap/load", [.int(4)])
        try await r.until("scoped recall") { r.sim.stringValue("/-snap/name") == "Renamed" }
        #expect(r.sim.value("/ch/01/mix/fader") == 321)
        #expect(r.sim.value("/ch/02/mix/fader") == 405 && r.sim.value("/ch/01/mix/on") == 0)
    }

    @Test func recorderSourcesAndTapsUseTheFirstTwoUSBRoutes() async throws {
        let r = try Rig(model: "XR16")
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        for side in 1...2 {
            let path = String(format: "/routing/usb/%02d", side)
            r.session.set(path + "/src", index: 35 + side)
            r.session.set(path + "/pos", index: 10)
            try await r.until("recording input") { r.sim.value(path + "/src") == 35 + side && r.sim.value(path + "/pos") == 10 }
        }
    }

    @Test func oversizedNumericInputStaysWithinTheParameterRange() throws {
        let s = ParameterStore()
        for path in ["/ch/01/mix/fader", "/ch/01/eq/1/q", "/ch/01/eq/1/f"] {
            let spec = try #require(s.spec(path))
            #expect(spec.index(from: .float(.greatestFiniteMagnitude)) == spec.maxIndex)
            #expect(spec.index(from: .float(-.greatestFiniteMagnitude)) == spec.minIndex)
            #expect(spec.index(from: .float(.nan)) == nil)
            #expect((spec.minIndex...spec.maxIndex).contains(spec.index(forValue: .greatestFiniteMagnitude)))
            #expect(ValueText.parse(spec: spec, token: String(repeating: "9", count: 120)) == nil)
        }
    }

    @Test func resyncNeverPushesWithAnAppToMixerPreference() async throws {
        let r = try Rig()
        defer { r.session.shutdown(); r.sim.stop() }
        try await r.connectAndSync()
        r.session.syncDirection = .appToMixer
        r.sim.externalSet("/ch/03/mix/fader", index: 421)
        r.session.resync()
        try await r.until("authoritative read-back") { r.session.state == .online }
        #expect(r.sim.value("/ch/03/mix/fader") == 421 && r.session.store.index("/ch/03/mix/fader") == 421)
        #expect(r.session.syncDirection == .appToMixer)
    }
}
