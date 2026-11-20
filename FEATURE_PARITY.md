# Feature parity: X-AIR-Edit 1.8.1 (macOS) → XAirModern (iOS/iPadOS 26)

Implementation and verification updated 20 November 2026. The source application is X-AIR-Edit 1.8.1 for macOS.

## Legend

**Evidence** (see PROTOCOL.md for detail):

| Tag | Source |
|---|---|
| D | Decompiled code |
| R | Runtime extraction from a scratch copy of the binary, stopped at `main` |
| O | The original app's own output file |
| S | UI strings in the binary |
| P | Prior report |
| I | Inference |
| M | Behringer X AIR user manual and remote control protocol |

**Simulator tested:**

| Value | Meaning |
|---|---|
| Unit | XAirKit tests (Swift Testing; package tests against the in-process and UDP mixer simulators) |
| UI | XCUITest in the iOS Simulator, against the in-app protocol simulator over real UDP |
| Visual | Rendered and inspected in screenshots only |

**Hardware validation.** Mixer-dependent claims await field testing. The last section lists the equipment and checks needed. Platform-only features carry a dash in this column.

## Connection and synchronisation

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Broadcast discovery (raw 6-byte `/xinfo` to 192.168.1.1, subnet broadcasts, 255.255.255.255) | all | P, D | Yes | Unit (loopback) | Pending | Needs the multicast entitlement on a physical device (README) |
| Manual IP connect (OSC `/xinfo` then `/status`) | all | P, D | Yes | Unit (real UDP), UI | Pending | — |
| Recent mixers, Rescan | all | S | Yes | Visual | Pending | — |
| `/status` handshake, firmware gate (≥ 1.09), model mapping (X18/XR18/XR16/XR12, V2, W, MR) | all | P, D | Yes | Unit | Pending | — |
| Sync mixer → app (79 or 82 prefs/stat/snap nodes + 693 nodes + USB directory + set clock + meters) | all | D, R | Yes | Unit | Pending | — |
| Sync app → mixer (push each node, then read back) | all | D | Yes | Unit | Pending | — |
| Keepalive `/xremotenfb` (2 s); external changes received | all | D | Yes | Unit | Pending | — |
| Link loss (10 s) → auto reconnect → resync | all | D | Yes | Unit | Pending | — |
| Connect failure and timeout messages; incompatible firmware message | all | D, S | Yes | Unit | Pending | — |
| Auto connect at launch, auto reconnect, sync direction preference | all | S, R | Yes | Visual | Pending | — |
| Disconnect, manual resync | all | S | Yes | Unit (resync) | Pending | — |
| Offline editing with a chosen model | all | S | Yes | Unit | Pending | — |
| Rename mixer (`/-prefs/name`) | all | R | Yes | Unit (string set) | Pending | — |
| Command-line options (`-n -i -x -p -s -f -d…`) | desktop | S | N/A | — | — | iOS has no CLI. The `-simulator`, `-connect`, `-tab` and `-strip` launch arguments exist for automation only |
| Prevent sleep while connected | all | S (1.7 notes) | Yes (idle timer) | Visual | Pending | — |

## Mixer surface

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Input channel strips, fader, mute, solo, pan, LR assignment and meter | All, including 16 DSP channels on XR12 | R, D, M | Yes | UI, Unit | Pending | Physical input count varies by model |
| Aux and FX return strips (stereo meters) | all | R, D | Yes | Visual, Unit | Pending | — |
| Bus masters, FX-send masters, Main LR | all | R | Yes | Visual, Unit | Pending | — |
| DCA 1–4 (fader, on, name, colour) | all | R | Yes | Visual | Pending | No DCA solo (no evidence for a solo-switch mapping) |
| Strip solo, global indicator, clear solo | All | D, R | Yes | Unit, UI | Pending | Desktop maps solo switches 01–32 to strips |
| Exclusive Solo, Follow last Solo (GUI prefs) | all | S | Yes | Visual | Pending | — |
| Sends on fader (bus 1–6, FX 1–4) | all | R, S | Yes | Visual | Pending | — |
| Fader layers: Inputs, Aux/FX, Buses, DCA | all | S | Yes | Visual | Pending | — |
| User layers 1 and 2 (`-localprefs/user1,2`) | all | R, S | Yes (local) | Visual | n/a | — |
| DCA spill | all | S (1.6 notes) | Yes | Visual | Pending | — |
| Strip meters and solo/monitor pair | All | D, M | Yes | Unit, Visual | Pending | Meter calibration on a mixer |
| Channel and bus stereo link, link preferences (client-side copy) | all | D | Yes | Unit | Pending | — |
| Channel copy and six independently selectable paste scopes | All | D, R, O | Yes | Unit | Pending | — |

## Channel editor

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Input source (`insrc`) with model-specific labels | all | R, D | Yes | Unit (labels), Visual | Pending | — |
| Gain and phantom through the mapped headamp | 16 / 8 / 4 mic preamps on XR18 / XR16 / XR12 | D, M | Yes | Unit, Visual | Pending | Audible gain and phantom switching |
| Polarity, low cut on/off and frequency, return trim | all | R | Yes | Visual | Pending | — |
| USB return switch and source | X18, XR18 | D | Yes | Visual | Pending | — |
| Gate: on, mode, threshold, range, attack, hold, release, key source, side-chain filter, transfer graph | ch 1–16 | R | Yes | UI audit, Visual | Pending | Graph is illustrative |
| Compressor/expander: all parameters, filter, auto, mix, graph | ch, bus, LR | R | Yes | Visual | Pending | — |
| Gate and compressor reduction, side-chain key level and key listen | Inputs, bus compressors, main compressor | D, R, M | Yes | Unit, Visual | Pending | Compare reduction, key and headphone monitoring against known signals |
| PEQ 4 bands (ch, rtn) / 6 bands (bus, LR): type, freq, gain, Q; interactive graph | all | R | Yes | UI (knob drag), audit | Pending | Curve uses RBJ biquads (display only) |
| Bus/LR EQ mode PEQ/GEQ/TEQ; 31-band GEQ editor | all | R | Yes | Visual | Pending | — |
| RTA over EQ (`/-stat/rta/source` + `/meters/4`) | all | S, R | Yes | Unit (`/meters/4`) | Pending | RTA bin frequencies (I) |
| Insert FX on/select | ch, bus, LR | R | Yes | Visual | Pending | — |
| Sends 1–10: level, tap, on, pan (odd sends) | ch, rtn | R | Yes | Visual | Pending | — |
| DCA and mute-group assignment (bitmasks), automix group/weight | all | R | Yes | Visual | Pending | — |
| Name and colour (16 colours incl. inverted) | all | R, D (palette) | Yes | Unit (name set), Visual | Pending | — |

## Effects

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| 4 FX slots, 61 effect types (long names), confirmation before changing type | all | R, D | Yes | Unit (retyping) | Pending | — |
| Per-type parameters with original labels, ranges and defaults | all | R | Yes | Unit, Visual | Pending | Generic controls, not bespoke per-effect panels |
| Insert vs send usage | all | R | Yes | Visual | Pending | — |
| FX return level/mute, FX send master | all | R | Yes | Visual | Pending | — |
| FX preset import/export and destination slot selection | All | D, O | Yes | Unit, desktop serializer fixture | Pending | — |
| FX input/output and algorithm-specific meters for Limiter, De-Esser, Fair Compressor and Combinator | All | D, M | Yes | Unit, UI (Precision Limiter) | Pending | Check register values against live audio |

## Routing

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Channel input routing | all | R | Yes | Visual | Pending | — |
| Aux outputs source/tap (6/4/2 active) | per model | R, D | Yes | Visual | Pending | — |
| Main and phones outputs | all | R | Yes | Visual | Pending | — |
| USB send routing (18), Ultranet P16 (16), USB returns | X18, XR18 | D | Yes | Visual | Pending | — |
| Routing file export and import with six independent recall scopes | Model-dependent | D, R | Yes | Unit | Pending | — |
| Twelve built-in routing presets, including cross-tab USB Plugin routes | X18, XR18, MR18 | D, R | Yes | Unit (all twelve), UI (USB return preset) | Pending | — |

## Scenes, snapshots, presets

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| 64 mixer snapshots, load, save, immediate rename and delete | All | D, R, M | Yes | Unit | Pending | Device storage and recall timing |
| Snapshot recall scope with 59 flags and per-strip safes | All | D, M | Yes | Unit (scope mask and partial simulated recall) | Pending | Console firmware owns the exact hardware recall boundaries |
| Scene file import/export, including 693-node scenes and partial lines | All | D, O | Yes | Unit (golden round trip) | Pending | — |
| Seven channel preset scopes and four/six-band EQ conversion | All, applicable channel sections only | D, O | Yes | Unit, desktop gate fixture | Pending | — |
| Confirm pop-ups preference | all | S | Yes | Visual | n/a | — |

## Recorder (USB stick)

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Stop, play, pause, record, fast-forward, rewind, file, elapsed/remaining and stereo recording/playback meters | XR12, XR16, MR12 | D, R, M | Yes | Unit, UI | Pending | Actual recording and media capacity |
| Browse USB folders, parent, refresh, play file, previous/next file while preserving transport state | XR12, XR16, MR12 | D, R | Yes | Unit, UI including real UDP | Pending | Filesystem and removable media |
| Play next | XR12, XR16, MR12 | R | Yes (toggle) | Visual | Pending | — |

## Meters and RTA

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Subscribe/renew/resubscribe/unsubscribe (`/batchsubscribe`, `/renew`) | all | D | Yes | Unit | Pending | — |
| Meter overview (channels, returns, buses, main, inputs, USB) | per model | D | Yes | Visual | Pending | — |
| RTA spectrum with source, tap, detector, decay, peak hold | all | R, S | Yes | Unit (data), Visual | Pending | Bin frequencies (I) |
| Meter 50% and RTA 50% rates | all | D | Yes | Unit (resubscribe path) | Pending | — |
| Utility main meter window | all | S | Yes (strips + overview) | Visual | Pending | — |

## Setup

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Global power-on mute, hard mutes, DCA mutes and recorder play-next | All, play-next on recorder models | R | Yes | Visual | Pending | — |
| Mute groups 1–4, automix X/Y enable and lock | all | R | Yes | Visual | Pending | — |
| Monitor/solo: level, source, trim, PFL/AFL modes, dim, mono, mute | all | R | Yes | Visual | Pending | — |
| Audio: sample rate, USB interface mode | X18, XR18 | D | Yes | Visual | Pending | — |
| MIDI configuration, all seven documented desktop bit positions | All | D, R | Yes | Visual, Unit (parameter codec) | Pending | Real DIN and USB traffic |
| LAN (static, DHCP, DHCP server), access point, Wi-Fi client, WLAN scan, apply, show password | all | R, S | Yes | Unit (scan in simulator), Visual | Pending | Applying network settings not exercised |
| Mixer actions: initialise all, save state, clear solo, set clock | all | R | Yes | Unit (initall, clearsolo) | Pending | — |
| Info (model, firmware, IP, hardware variant, capabilities, link statistics) | all | P | Yes | Visual | Pending | — |
| Firmware update (`.update`, V1/V2 check, UDP 10018 protocol) | all | D | Yes | Unit (fake updater only) | **Not authorised** | Never run against hardware |

## Platform and app

| Feature | Models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Five compact tabs and a seven-section native iPad sidebar, rotation | iPhone and iPad | SwiftUI | Yes | Visual, UI in portrait and landscape | — | — |
| Light and dark appearance | — | — | Yes | Visual (both) | — | — |
| Dynamic Type and VoiceOver control semantics | iPhone and iPad | SwiftUI, XCTest | Yes | UI accessibility audits on Mixer and Channel EQ | — | Manual VoiceOver listening and the other screens await a full accessibility assessment |
| Liquid Glass (system bars/tabs; glass on status, chips, toolbar items) | — | — | Yes | Visual | — | — |
| Local network privacy string; multicast entitlement | — | — | Yes | Build | Pending | Entitlement needs Apple approval for device builds |
| Deterministic simulator (X18/XR18/XR16/XR12) | — | — | Yes | Unit, UI | — | — |
| Window restoration, always-on-top, desktop scaling, mouse-wheel options and desktop shortcut editor | macOS | S | Desktop-specific | — | — | iPad provides a native sidebar, system text sizing and keyboard commands |
| Inverted mute display, fine fader movement, select on fader move and linked send taps | All | D, R | Yes | Unit (send/link behavior), Visual | Pending | Touch sensitivity and keyboard increments are iOS adaptations |

## Additional desktop controls and files

| Feature | Applicable models | Evidence | Implemented | Simulator tested | Hardware tested | Remaining gap |
|---|---|---|---|---|---|---|
| Selected strip input/output, key and reduction meters | All applicable strips | D, M | Yes | Unit, Visual | Pending | Known-signal comparison |
| Automix gains, four DCA meters, output, Ultranet and headphones meters | Per connector and model | D, M | Yes | Unit, Visual | Pending | Known-signal comparison |
| Four- and six-band factory EQ reset | Inputs, returns, buses, LR | D, R | Yes | Unit | Pending | — |
| Recorder left/right input selection and tap position | XR12, XR16, MR12 | D, R | Yes | Unit, Visual | Pending | Record a file from independently selected sources |
| Subgroup default bus assignment and subgroup taps | XR12 buses 3–6, XR16 buses 5–6 | D, M | Yes | Unit | Pending | Listen at the main and auxiliary outputs |
| Linked tap-point edits from a source strip or a bus master | All | D | Yes | Unit | Pending | — |
| Effective hard group and DCA mutes, overlapping soft mute groups | All | D | Yes | Unit | Pending | Listen through overlapping assignments |
| Keyboard screen, channel, fader, mute/solo, processing, layer, FX and recorder actions | iPad with keyboard | S, D and platform adaptation | Yes | UI for screen navigation | Pending | Physical keyboard |
| Show management | X AIR desktop | D, M, O | Mixer snapshots and individual scenes | Unit | Pending | The supplied client exposes scene files and a 64-slot snapshot bank. No separate show-file format was identified. |

## Verification and remaining field work

Build commands, device names, results and screenshot links are in the [README](README.md). The detailed meter map, recorder protocol and file formats are in [PROTOCOL.md](PROTOCOL.md). The fixtures come from a stopped desktop process, and all device interactions in the automated suites use local simulators.

Physical validation requires an X18/XR18-family mixer for its USB interface and Ultranet, and an XR12/XR16-family mixer for the USB stick recorder. The smaller models have different input and auxiliary connector counts. Device testing should cover actual preamp gain, phantom power, audio and MIDI paths, meter calibration, snapshot persistence, removable media, and reconnection over Wi-Fi. Physical discovery also requires a signed build with Apple's multicast entitlement. Firmware transfer was exercised exclusively with a fake updater.
