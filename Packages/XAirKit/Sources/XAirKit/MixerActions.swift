import Foundation

extension MixerSession {
    /// ChannelSends applies a tap to the same destination on all 21 input/return strips when linked.
    public func setSendTap(strip: Int, send: Int, index: Int) {
        guard (0..<21).contains(strip), (1...10).contains(send) else { return }
        let suffix = String(format: "/mix/%02d/tap", send)
        let sources = linkSendTaps ? 0...20 : strip...strip
        for source in sources {
            let path = SceneFiles.channelBase(source) + suffix
            if store.index(path) != index { set(path, index: index) }
        }
    }

    public func keySoloIndex(strip: Int, gate: Bool) -> Int? {
        let token: String
        switch strip {
        case 0..<16: token = String(format: gate ? "G%02d" : "D%02d", strip + 1)
        case 21..<27 where !gate: token = "DB\(strip - 20)"
        case 31 where !gate: token = "DLR"
        default: return nil
        }
        return store.spec("/-stat/keysolo")?.enumItems.firstIndex(of: token)
    }

    private var activeMuteMask: Int {
        (0..<4).reduce(0) { $0 | (store.bool("/config/mute/\($1 + 1)") ? 1 << $1 : 0) }
    }

    internal func updateSoftMutes(group: Int, engaged: Bool) {
        guard !store.bool("/-prefs/hardmute") else { return }
        let active = activeMuteMask
        for strip in 0..<31 {
            let base = SceneFiles.channelBase(strip)
            let membership = store.index(base + "/grp/mute")
            guard membership & (1 << (group - 1)) != 0, engaged || membership & active == 0 else { continue }
            let path = base + "/mix/on"
            if store.bool(path) == engaged { set(path, index: engaged ? 0 : 1) }
        }
    }

    public func groupMutes(strip: Int) -> Bool {
        guard (0..<31).contains(strip) else { return false }
        let base = SceneFiles.channelBase(strip)
        if store.bool("/-prefs/hardmute"), store.index(base + "/grp/mute") & activeMuteMask != 0 { return true }
        guard store.bool("/-prefs/dcamute") else { return false }
        let dcas = store.index(base + "/grp/dca")
        return (0..<4).contains { dcas & (1 << $0) != 0 && !store.bool("/dca/\($0 + 1)/on") }
    }
}

public enum RecorderAction: CaseIterable, Sendable {
    case stop, play, pause, record, rewind, fastForward

    public func target(from state: Int) -> Int? {
        switch self {
        case .stop: return 0
        case .play: return [3, 4].contains(state) ? nil : 2
        case .pause: return [1: 2, 2: 1, 3: 4, 4: 3][state]
        case .record: return [0: 4, 3: 4, 4: 3][state]
        case .rewind: return [1, 2].contains(state) ? 6 : nil
        case .fastForward: return [1, 2].contains(state) ? 5 : nil
        }
    }
}

public struct RecorderEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let path: String
    public let isFolder: Bool
}

extension MixerSession {
    public var recorderAvailable: Bool {
        state == .online && model?.hasUSBRecorder == true && store.bool("/-stat/usbmounted")
    }

    public var recorderEntries: [RecorderEntry] {
        guard recorderAvailable, !directoryLoading, directoryError == nil else { return [] }
        let directory = store.string("/-stat/usb/path")
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return schema.usbDirPaths.prefix(max(0, store.index("/-stat/usb/count"))).enumerated().compactMap { i, node in
            let name = store.string(node + "/name")
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  store.value(node + "/name")?.received == true,
                  store.value(node + "/type")?.received == true else { return nil }
            return RecorderEntry(id: i, name: name, path: prefix + name, isFolder: store.index(node + "/type") == 1)
        }
    }

    public func recorderTransport(_ action: RecorderAction) {
        let path = "/-stat/tape/state"
        guard recorderAvailable, let target = action.target(from: store.index(path)) else { return }
        set(path, index: target)
    }

    public func openRecorderEntry(_ entry: RecorderEntry, play: Bool = true) {
        guard recorderEntries.contains(entry), entry.path.utf8.count <= 255 else { return }
        if entry.isFolder {
            set("/-stat/usb/path", string: entry.path)
            refreshRecorderDirectory()
        } else {
            set("/-stat/tape/file", string: entry.path)
            if play { recorderTransport(.play) }
        }
    }

    public func adjacentTrack(forward: Bool) -> RecorderEntry? {
        let tracks = recorderEntries.filter { !$0.isFolder }
        guard let current = tracks.firstIndex(where: { $0.path == store.string("/-stat/tape/file") }) else {
            return forward ? tracks.first : nil
        }
        let next = current + (forward ? 1 : -1)
        return tracks.indices.contains(next) ? tracks[next] : nil
    }

    public func recorderParentDirectory() {
        let path = store.string("/-stat/usb/path")
        guard recorderAvailable, !directoryLoading, !path.isEmpty, path != "/" else { return }
        let parent = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        set("/-stat/usb/path", string: parent)
        refreshRecorderDirectory()
    }

    internal func observeDirectoryChanges(_ changes: [ParamChange]) {
        guard state == .online, model?.hasUSBRecorder == true else { return }
        if changes.contains(where: { $0.path == "/-stat/usbmounted" }), !recorderAvailable {
            directoryGeneration &+= 1
            directoryLoading = false
            directoryError = nil
        } else if !directoryLoading, changes.contains(where: { ["/-stat/usb/path", "/-stat/usb/count", "/-stat/usbmounted"].contains($0.path) }) {
            refreshRecorderDirectory()
        }
    }

    public func refreshRecorderDirectory() {
        guard recorderAvailable else { return }
        directoryGeneration &+= 1
        let generation = directoryGeneration
        directoryLoading = true
        directoryError = nil
        requestNode("/-stat/usb") { [weak self] ok in
            guard let self, self.directoryGeneration == generation else { return }
            guard ok else {
                self.directoryLoading = false
                self.directoryError = "The mixer did not return the USB directory."
                return
            }
            let path = self.store.string("/-stat/usb/path")
            let nodes = self.schema.usbDirPaths.prefix(max(0, self.store.index("/-stat/usb/count")))
            var remaining = nodes.count
            if remaining == 0 { self.directoryLoading = false }
            for node in nodes {
                self.requestNode(node) { [weak self] ok in
                    guard let self, self.directoryGeneration == generation else { return }
                    if !ok { self.directoryError = "The mixer did not return all USB entries. Refresh to retry." }
                    remaining -= 1
                    if remaining == 0 {
                        self.directoryLoading = false
                        if self.store.string("/-stat/usb/path") != path || self.store.index("/-stat/usb/count") != nodes.count {
                            self.refreshRecorderDirectory()
                        }
                    }
                }
            }
        }
    }
}
