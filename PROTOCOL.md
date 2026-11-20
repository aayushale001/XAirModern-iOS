# X Air mixer protocol, as used by X-AIR-Edit 1.8.1

Reconstructed for XAirModern (iOS/iPadOS) from the shipped desktop app. The protocol is OSC over UDP.

**Target:** `X-AIR-Edit.arm64` (Mach-O arm64, JUCE app). sha256 `fe5581370f2b8e9f1069e1e966530f366e2c05de7c5730ed5d98148db97232c2`. Release notes say 1.8.1; `CFBundleVersion` says 1.8.0.

**Tools:** REA 6.8 with Ghidra 12.1.4, `llvm-objdump`, and `lldb` on an ad-hoc re-signed **scratch copy** of the binary. The original app and binary were never modified (the hash was checked before and after).

**Evidence key** (used throughout):

| Tag | Meaning |
|---|---|
| **[D]** | Decompiled or disassembled code in the binary. The REA Evidence ID is given where one exists; IDs are reproducible by reopening the same binary. |
| **[R]** | Runtime extraction. Functions inside the scratch copy were run while it was stopped at `main`, before any socket existed: `Croot::Croot()`, `Cfxunit::update()`, and the static tables. Dumps are in `research/runtime-dumps/`. |
| **[O]** | The desktop default-state file and output from the desktop preset serializer. |
| **[P]** | Prior report: `../rea-discovery-report.md`. |
| **[I]** | Inference. Section 13 records the open hardware checks. |
| **[M]** | Behringer’s X AIR user manual, especially §3.1–3.2 on physical I/O and internal signal routing. |

The manufacturer also documents parameter enquiries, meter IDs and snapshot scopes for mixer firmware 1.11 onward. The packet traces used for testing come from the local simulator. [Behringer X AIR user manual](https://images.thomann.de/pics/atg/atgdata/document/manual/333932_x_air_manual_en.pdf#page=13) · [Behringer remote control protocol](https://cdn-media.empowertribe.com/fa303061bf2f48a7b07eba14e1c82271/X%20AIR%20Remote%20Control%20Protocol.pdf)

---

## 1. Transport

| Item | Value | Evidence |
|---|---|---|
| Port | Mixer UDP **10024** for OSC; **10018** for the firmware updater | [P] `UdpConnection::initialiseSocket` 0x1000e5e3c; [D] `ConnectPage::run` 0x100076d90 |
| Client socket | `AF_INET`/`SOCK_DGRAM`, bound to `INADDR_ANY:0` (random port). `SO_BROADCAST=1`, `SO_REUSEADDR=1`, 64 KiB send and receive buffers. | [P] `DatagramSocket` ctor 0x1001353f4, `bindToPort` 0x1001356a4 |
| Receive | 1500-byte reads. A datagram is accepted only if its length is non-zero and a multiple of 4. The sender address is **not** checked. | [P] `UdpConnection::run` 0x1000e5bd8 |
| Encoding | oscpack: big-endian, 4-byte aligned. Type tags used: `i`, `f`, `s`, `b`. No bundles. | [D] `OutboundPacketStream`, `Cparam::getOscMessage` (`ev_d98dae43…`) |

XAirModern additionally drops parameter traffic that does not come from the connected mixer's IP and UDP port. Every in-app simulator uses its own loopback port.

## 2. Discovery and connection

1. **Probe.** The app writes the 6 raw bytes `/xinfo` (no NUL, no padding) to `192.168.1.1`, then up to 5 subnet broadcasts (`addr | ~mask`, skipping text that starts with `127.0.0.1`), then `255.255.255.255`, with 20 ms between sends. [P]
2. **Reply.** `/xinfo ,ssss` carries IP, NAME, MODEL and FW, in that order. [P][D] `OscCom::handleMessage` (`ev_86ed406c…`)
3. **Status.** The app sends `/status` with no arguments. The reply is `/status ,sss`; the connect code receives argument 1 (IP) and argument 2 (name). [P][D]
4. **Firmware gate.** The check is on character positions: `fw[0] > '0'`, `fw[2] >= '0'`, and `(fw[2] != '0' || fw[3] > '8')`. In practice this means "1.09 or later". Otherwise the app shows "Incompatible Mixer Firmware!". [P]
5. **Model map** (`_Xmdl`):

   | Model string | `_Xmdl` |
   |---|---|
   | X18, X18V2 | 0 |
   | XR18, XR18V2, MR18, MR18V2 | 1 |
   | XR16, XR16W | 2 |
   | XR12, XR12W, MR12, MR12W | 3 |

   Two hardware flags are also set: V2 (XR18V2/MR18V2/X18V2), and V2 or W. [P]
6. **While offline,** the app sends OSC `/xinfo` to the chosen host every 2 s. This is the reconnect probe. [D] `OscSub::run` (`ev_49ffb685…`)

**Manual IP** in XAirModern sends an OSC-encoded `/xinfo` straight to the address, then `/status` when the reply arrives. No broadcast is needed.

## 3. Synchronisation (`OscCom::run`, [D] `ev_345a0263…`)

A *node request* is the node path sent as an OSC message **with no arguments**, for example `/ch/01/config`. The mixer replies with the same address carrying every parameter of that node as typed arguments, in child order.

1. **Prefs, status and snapshots.** The app requests the `prefstatsnap` table first:
   - **79** entries on X18/XR18;
   - **82** on XR16/XR12, which adds `/-stat/tape`, `/-stat/usb` and `/-stat`.

   The table is `/-prefs…`, `/-snap/01…64`, `/-snap`, `/-stat/solosw`, `/-stat/rta`, … [R] `tables.prefstatsnap`
2. **Main sync,** depending on the sync direction:
   - **Mixer → app:** each of the 693 `allpaths` nodes is requested. [R] `syncPaths`
   - **App → mixer:** each node is sent as `/<node> ,<types> args…` (int/enum as `i`, float laws as `f`, strings as `s`), and the app waits for the same address to come back.

   Pending requests are re-sent every 500 ms. Progress is `count/693`.
3. **USB directory (XR16/XR12 only).** The app requests `/-stat/usb/001…` up to `/-stat/usb/count`. [R] `recpaths`
4. **Clock.** `/-action/setclock ,s "YYYYMMDDhhmmss"`.
5. **Meters.** Subscriptions to `/meters/1` and `/meters/6` (§6).

The text-form reply `node ,s "<path> tok tok…"` (address `node`, no slash) is also accepted, parsed with the rules in §5, and clears the pending request. [D]

XAirModern keeps 4 requests in flight instead of 1, and caps retries at 8 per node. A failed node is listed in Setup ▸ Info rather than retried forever; the original retries without limit. In App → Mixer mode each pushed node is read back, so the mixer stays authoritative.

## 4. Parameter model (`Cparam`, [D] `ev_d98dae43…`, [R] `tree.jsonl`)

Every value is an integer **step index** (`Cparam+0x5c`), except strings.

| Type code | Kind | Index → value (`getFloat`) | Wire format |
|---|---|---|---|
| `0xc1` | int (`%d`, `%%%04b`, …) | i | `i` |
| `0xc2` | enum | i (item list) | `i` |
| `0xc3` | linear | min + (max−min)·i/steps | `f` = i/steps |
| `0xc4` | log | min·exp(k·i), where k = ln(max/min)/steps is stored | `f` = i/steps |
| `0xc5` | string (max length) | — | `s` |
| `0xc6` | fader level (`#f`, 1023 steps) | 4-segment law, below | `f` = i/steps |
| `0xc7` | send level (`#l`, 160 steps) | same law | `f` = i/steps |

- **Inbound `f`:** i = (int)((steps + 0.5)·f), clamped. **Inbound `i`:** clamped. **Inbound `s`:** applied only to string parameters. A node message fills its parameters in order. [D] `CmessageQueue::run` (`ev_845b7dba…`)
- **Fader law** (n = steps):

  | Index range | dB |
  |---|---|
  | i ≥ (n+1)/2 | i·40/n − 30 |
  | i ≥ (n+1)/4 | i·80/n − 50 |
  | i ≥ (n+1)/16 | i·160/n − 70 |
  | i = 0 | −∞ (−144) |
  | otherwise | i·480/n − 90 |

  The inverse (`setFloat`) uses the same breakpoints at −10, −30 and −60 dB, rounds as `(int)(x+0.5)`, and treats ≤ −90 dB as index 0.
- **Every range, step count, enum list and display format** is in `Packages/XAirKit/Sources/XAirKit/Resources/xair-schema.json`: 1,059 nodes, 3,776 parameters, 70 enum lists. It was generated by `tools/gen_schema.py` from [R]. Examples:

  | Parameter | Range |
  |---|---|
  | `/ch/NN/mix/fader` | 1023 steps |
  | `/ch/NN/eq/B/f` | log, 20 Hz–20 kHz, 200 steps |
  | `/ch/NN/eq/B/g` | ±15 dB, 120 steps |
  | `/ch/NN/eq/B/q` | log, 10–0.3, 71 steps |
  | `/headamp/01-16/gain` | −12…+60 dB, 144 steps |
  | `/headamp/17-24/gain` | −12…+20 dB, 64 steps |
  | `/ch/NN/mix/MM/level` | 160 steps |

- **FX parameters** `/fx/N/par/01…64` change type with the effect. `Cfxunit::update` applies `Cfxdsp::fxparcfg_<ALG>` through `fxalg[type]`. Each entry is `{min, max, steps (>0 linear, <0 log), fmt, …, default, label}` ([D] `ev_0c009bbe…`). The resolved per-type definitions for all 61 types, including labels and defaults, come from [R] `fx.json`. Unused slots are padded with `0` in text files. [O]
- **Link-excluded parameters** (`Cparam+0x69`): name, `insrc`, `rtnsrc`, pans, key sources and `insert/sel`. [R]

## 5. Text format (scene, preset and `node` lines)

`path tok tok …`, with strings in double quotes. Full scenes omit the leading slash. Channel presets use slash-prefixed paths relative to the saved strip. FX presets use paths relative to the slot (§10). Tokens are produced by `Cparam::getString` through the app's own printf `myspf` ([D] `ev_09cbafbe…`):
- `%f` defaults to 0 decimals.
- The `k` flag prints values ≥ 1000 as `1k97`.
- With an explicit width, the number of decimals is whatever fits, so `%4.2f` prints 502.38 as `" 502"`.
- A rounding offset of {0.5, 0.05, 0.005, 0.0005} (float32, `rndfi` @0x1002d4c38) is added before truncation.
- Levels print as `"  0.0"`, `%+5.1f`, or `"  -oo"`.

Parsing follows `Cparam::setString`:
- `-oo` means −∞.
- `k` notation is accepted (`10k02` = 10020).
- `%0101` is binary.
- `#n` sets an enum by index.
- A leading `\` means "unchanged".

**Validation:** all 693 lines of the original's own `X-AIREdit.default.init` round-trip byte-for-byte in `TextFormatTests.defaultSceneRoundTripsExactly`. [O]

## 6. Keepalive, meters and link loss (`OscSub::run`, [D] `ev_49ffb685…`)

The work loop runs every 50 ms.

| Every | When | Message |
|---|---|---|
| 2 s | online | `/xremotenfb` (remote updates, no echo of our own sets) |
| 2 s | offline | `/xinfo` to host |
| 2 s per meter subscription | renew states 1–5 | `/renew ,s "meters/N"` |
| 6th cycle (~10 s) | — | full `/batchsubscribe` again |

- **Subscribe:** `/batchsubscribe ,ssiii "meters/N" "/meters/N" sel sel rate` ([D] `send_metersrequest`):
  - `sel` is the selected channel (`_local→chan→selidx`); the member map comes from the `Clocal` constructor disassembly.
  - `rate` = `updrate + 1`, i.e. 1 or 2 for the "Meter 50%" preference; "RTA 50%" applies to block 4.
- **Unsubscribe:** `/unsubscribe ,s "meters/N"`.
- **Link loss:** no meter data for 10 s means the link is lost. The app goes offline, then either auto-reconnects (if the preference is on) or asks "Try reconnect?". In the original, the receive timer is refreshed only by meter packets; XAirModern refreshes it on any packet from the mixer.

## 7. Meter packets ([D] `OscCom::handleMessage`, `FaderSection::processMessage` `ev_ba9f51aa…`, `MeterIO::processMessage` `ev_ecd5450f…`, `mFader::setMeter` `ev_64af53cd…`)

- **Address** is `meters/N` with **no leading slash**, followed by a single `b` argument.
- **Blob layout:** `[int32 LE count][count × int16 LE]`. The app requires blobSize/2 − 2 == count == `meterbatchsize[N]`.
Audio level and dynamics readings use signed dB × 256. The ten internal FX readings per slot have units specific to the effect. Each ID has a fixed length. [Behringer remote control protocol, pp. 2–4](https://cdn-media.empowertribe.com/fa303061bf2f48a7b07eba14e1c82271/X%20AIR%20Remote%20Control%20Protocol.pdf#page=2)

| Block | Count | Registers, numbered from zero |
|---|---:|---|
| 0 | 8 | Selected strip. Input L/R at 0/1, gate/compressor reduction at 2/3, output L/R at 4/5, gate/compressor key at 6/7. |
| 1 | 40 | Channels 0–15, aux L/R 16–17, four stereo FX returns 18–25, six buses 26–31, four FX sends 32–35, main L/R 36–37, solo/monitor L/R 38–39. |
| 2 | 36 | Physical input positions 0–15, aux L/R 16–17, USB inputs 18–35. The model determines which connectors exist. |
| 3 | 56 | Four consecutive ranges of 14. Relative to the slot start, 0/1 are inputs, 2–11 are processor readings, 12/13 are outputs. |
| 4 | 100 | RTA bins in frequency order. The EQ graph uses a logarithmic 20 Hz–20 kHz axis. |
| 5 | 44 | Aux outputs 0–5, main L/R 6–7, Ultranet 8–23, USB sends 24–41, headphones 42–43. |
| 6 | 39 | Channel gate reduction 0–15, channel compressor reduction 16–31, bus compressor reduction 32–37, main compressor reduction 38. |
| 7 | 16 | Automix channel gains. |
| 8 | 4 | DCA 1–4 levels. |
| 9 | 4 | Record L/R at 0/1, playback L/R at 2/3. Used by the two-track USB recorder. |

The gate and dynamics handlers send block 0 registers 6/7 to the faders bound to their respective thresholds and 2/3 to the separate reduction meters. The effects view interprets the internal registers for the limiter, de-essers, Fair Compressors and Combinators with the algorithm's native scale. Views share a subscription when they use the same block. [Desktop handler findings](research/FINDINGS-2026-11-20.md)

## 8. Sets, links, solo and snapshots

- **Set** a parameter: `/<leaf path> <one arg>` using the wire format of §4. Local edits are sent; values that arrived from the mixer are not re-sent (`Cnode::notify` 'N' vs `oscNotify` 'I'). [D] `ev_40f16eec…`
- **Channel and bus links are done by the client.** While `/config/chlink/a-b` or `/config/buslink/a-b` is ON, the partner channel or bus gets the same index (`Cnode::copyLinkCh`), except link-excluded parameters. Copying is gated by `/config/linkcfg` according to the parent node type:

  | Parent node type | Gate |
  |---|---|
  | 7 (preamp) | `preamp` |
  | 12–14 (EQ, GEQ) | `eq` |
  | 8–10 (gate, dyn, insert) | `dyn` |
  | 16 (mix, grp) | `fdrmute` |
  | others | always copied |

  When a link is switched ON, every eligible parameter is copied. Headamp gain and phantom follow the partner's input source when `linkcfg/preamp` is ON. [D] `CmessageQueue::run`
- **Solo:** `/-stat/solosw/01…32`:
  - 01–16: ch 1–16;
  - 17: aux;
  - 18–21: FX returns;
  - 22–27: buses;
  - 28–31: FX sends;
  - 32: LR.

  `/-stat/solo` is the global indicator and `/-action/clearsolo` clears everything. [D] `solo_setupcuemix` `ev_edadf309…`. The desktop uses 01–32 for strip solo. The additional stat fields have no observed strip or DCA control. Side-chain listen uses the separate enum at `/-stat/keysolo` for 16 gates, 16 channel compressors, six bus compressors and the main compressor.
- **Snapshots:**
  - Commands: `/-snap/load ,i n`, `/-snap/save ,i n`, `/-snap/delete ,i n`; names in `/-snap/name` and `/-snap/NN/name`, the current one in `/-snap/index`. [R]
  - **Scope (safes):** `/-snap/NN/scope` is 59 characters, `'+'` = recalled, matching the 59 `scope_txt` labels. At least one must be selected. [D] `getSnapshotScopes` / `isSnapshotScope` `ev_fd01e47c…`
  - Saving sets the temporary name and then saves the numbered slot. Loading needs only the slot number. Renaming writes the slot name directly. A scope edit also takes effect immediately. The app reads back the mixer after recall.
- **Actions** (`/-action/…`):

  | Action | Values |
  |---|---|
  | `initall`, `savestate`, `wlanscan` | enum `-`/`GO` |
  | `updnet` | `-`/`LAN`/`IS`/`AP` |
  | `clearsolo` | — |
  | `setclock` | string (14 characters) |
  | `editname`, `pastepreset` | — |

  [R]

## 9. Firmware update (UDP 10018, [D] `ConnectPage::UpdateFirmware` `ev_0d88db1a…`, `ConnectPage::run` `ev_31d86f9d…`)

**File check.** The file must have the `.update` extension and must not be a directory. A file whose name contains `V2`/`v2` is accepted only when the hardware flag is V2; any other file only when it is V1. The error messages are "Wrong update file! Please use a V1/V2 update file."

**Transfer:**
1. Send `us**`, then wait up to 500 ms for a reply whose first byte is `Y`.
2. For each 1024-byte chunk, send a **1032-byte** packet: `sW**`, then the LE uint32 offset, then the 1024-byte buffer. The buffer is reused, so the last packet carries stale tail bytes from the previous chunk. Each packet needs a `Y` acknowledgement within 500 ms, with up to 3 attempts.
3. If more than 0x2800 bytes were sent, send `sUpd`, sleep 500 ms, wait for `Y`, then send `ur**`. The app shows "Device will reboot now!".

XAirModern reproduces this exactly. It is gated behind an ownership acknowledgement and a confirmation, and has been **tested only against a fake updater**.

## 10. Files

| File or action | Desktop format and iOS handling |
|---|---|
| Scene | 693 node lines, no header. Full scene output round-trips the original default file byte-for-byte. Partial file lines apply only supplied recognised fields. |
| Channel preset | Desktop uses the selected strip as the root. A gate preset contains `/gate` and `/gate/filter`. Source saves the preamp plus `/config/insrc` and `/config/rtnsrc`. Output saves individual on, fader, LR and pan leaves. Complete, EQ, dynamics and sends use the node lists from `Cpreset::savePreset` at 0x1000342fc. |
| Channel copy/paste | Config, preamp, gate, EQ, dynamics and mix can be recalled independently. Across four- and six-band EQs, the four corresponding positions are 1, 3, 4 and 6 in the six-band layout. |
| Effect preset | Three relative lines, `type`, `insert` and `par`. The parameter line is padded to 64 values. Import resolves the destination slot’s parameter types before applying values. |
| Routing file | Input source, USB return source/switch, USB output, Ultranet, aux and main/phones are independently selectable. Non-routing fields in a scene are skipped. The 12 built-ins each apply all of their original lines, including the cross-tab USB Plugin routes. |
| EQ initialisation | The desktop embeds distinct four- and six-band reset curves. They are packaged with the routing preset data. |

The bundled gate and effect fixtures were produced by the desktop serializer `Cnode::getAllParams` at 0x10001e410. The fixture tests import them at a different destination and compare the exported text. [Preset and routing evidence](research/FINDINGS-2026-11-20.md)

## 11. Model differences

| | X18 / XR18 | XR16 | XR12 | Evidence |
|---|---|---|---|---|
| Mono DSP strips | 16 | 16 | 16, 12 physical inputs | [M], [D] `state_initializeConsole`, `ChannelInput::setParams` (`ev_ce141dc4…`) |
| Mic preamps (phantom) | headamps 1–16 | 1–8; inputs 9–16 use line headamps 17–24 | 1–4; inputs 5–12 use headamps 17–24 | [D] |
| Input labels | `01…18, Off` | `01…16, L, R, Off` | `01…12, L, R, Off` | [R] `input_txt`, `inputXR16_txt`, `inputXR12_txt` |
| Aux outputs (others default to GRP) | 6 | 4 | 2 | [D] defaults in `state_initializeConsole` |
| 18-channel USB interface (`rtnsw`/`rtnsrc`, `routing/usb`, clock and USB mode) | yes | no | no | [D] `ChannelInput::setParams`, `MixerSetup::resized` |
| Routing tabs | 6 (adds USB send, Ultranet/P16, USB returns) | 3 | 3 | [D] `RoutingModuleTabbedComponent::buttonClicked` `ev_58a8e9ee…` |
| USB stick recorder (`/-stat/tape`, `/-stat/usb`) | no | yes | yes | [D] `OscCom::run` (sync), [R] |
| Prefs/stat/snap paths synced | 79 | 82 | 82 | [D] |

## 12. Recorder and client behaviours

On XR12/XR16 the recorder’s left and right recording selectors bind to `/routing/usb/01/{src,pos}` and `/routing/usb/02/{src,pos}`. The source table contains 38 choices and the tap table contains 11. These two recording routes are independent of the model’s 18-channel USB interface capability. Both selector pairs were resolved to named leaves inside the desktop runtime.

Setting `/-stat/usb/path` changes folder. The client requests the directory header, then each numbered entry through the reported count, up to 200. Type 1 is a folder. Selecting a track sets `/-stat/tape/file` and then playback state 2. Previous and next change the file while preserving the current transport state. The desktop state machine uses stop, playback pause, play, record pause, record, fast-forward and rewind at indices 0–6. [Recorder transport and evidence](research/FINDINGS-2026-11-20.md)

A soft mute group edits the assigned strips. Releasing a group considers the remaining active groups. Hard-group and DCA mutes contribute to the effective mute display. The seven MIDI configuration bits, starting at bit zero, are DIN receive, DIN transmit, DIN X-OSC, USB receive, USB transmit, USB/OSC and USB-to-DIN pass-through. The local link-sends preference propagates only the selected destination’s tap across the 21 source strips.

## 13. Hardware validation

The original desktop client, its serializer and the manufacturer’s protocol establish the mappings above. Physical preamps, audio routing, audible DSP, meter calibration, storage media, LAN discovery, reconnect under live traffic and device provisioning await a mixer and a signed iPhone or iPad. The EQ and dynamics curves are visual estimates. Exact RTA bin centre frequencies and hardware timing remain unmeasured. The firmware transfer has only been exercised against the local test updater.
