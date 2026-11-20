# XAirModern

XAirModern is a native SwiftUI controller for Behringer X18, XR18, XR16 and XR12 mixers and Midas MR18 and MR12 mixers. It targets iOS and iPadOS 26 or later. Its parameter schema, file formats and control behaviour were reconstructed from X-AIR-Edit 1.8.1 and checked against Behringer’s protocol documentation. [Feature parity](FEATURE_PARITY.md) · [OSC protocol and model differences](PROTOCOL.md) · [Desktop evidence](research/FINDINGS-2026-11-20.md)

## Install the IPA on iPhone

You need an iPhone running **iOS 26.0 or later**. AltStore Classic signs the IPA for your iPhone using your Apple Account. If AltStore Classic already opens on your phone, start at step 3.

1. On your Mac or Windows PC, install and run **AltServer**. Connect your unlocked iPhone by USB, tap **Trust** if prompted, then choose **Install AltStore** and your iPhone from the AltServer menu. To install or refresh apps over Wi-Fi later, enable Wi-Fi sync as shown in the guide for your computer. [macOS setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) · [Windows setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
2. On the iPhone, trust your own developer account under **Settings → General → VPN & Device Management** if prompted. Turn on **Settings → Privacy & Security → Developer Mode**, restart the phone and confirm after unlocking. [Apple’s Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
3. In Safari on your iPhone, download `XAirModern-1.0-sideload.ipa` and find it in the **Files** app. [Download the iPhone IPA](https://github.com/aayushale001/XAirModern-iOS/releases/download/v1.0/XAirModern-1.0-sideload.ipa) · [GitHub release](https://github.com/aayushale001/XAirModern-iOS/releases/tag/v1.0)
4. Keep AltServer running and connect your iPhone to the computer by USB or the same Wi-Fi. Open **AltStore Classic → My Apps**, tap **+** and select the IPA from Files. When installation finishes, open **X Air Modern** from the Home Screen. [AltServer connection guide](https://faq.altstore.io/altstore-classic/altserver)

With a free Apple Account, the app’s signing profile lasts seven days. To renew it before it expires, choose **My Apps → Refresh All** while AltServer is reachable. [AltStore refresh guide](https://faq.altstore.io/altstore-classic/your-altstore)

## Use the app on iPhone

**Try it without a mixer.** On the connection screen, tap **Simulated XR18**. In **Mixer**, drag a fader, tap a channel name, then open **Channel** to edit its EQ. To try the USB recorder, use the **⋯** connection menu to **Disconnect**, choose **Simulated XR12**, then open **Tools → Setup → Recorder**. The built-in mixers run locally over UDP and supply simulated meter and recorder data. [iPhone mixer screenshot](screenshots/iphone-mixer-XR18.png)

**Connect to a real mixer.** The release IPA omits the entitlement for broadcast discovery. You can connect by IP even when the **Mixers on this network** list is empty.

1. Join the mixer’s Wi-Fi network on your iPhone, or join the same router as the mixer. If you are using the simulator, tap **⋯ → Disconnect** to return to the connection screen.
2. Allow **Local Network** access when iOS asks. You can enable it later under **Settings → Privacy & Security → Local Network → X Air Modern**.
3. Under **Connection options**, choose **Mixer → App (recommended)** to read the console’s current mix. Under **Connect by IP address**, enter the mixer’s address and tap **Connect**. Use `192.168.1.1` in the mixer’s own access-point mode. With a router, use the address assigned to the mixer.
4. Wait for synchronization to finish. The faders now control the live console. Use **Mixer** for levels and mutes, **Channel** for EQ and dynamics, and **Tools** for routing, meters and setup.

For offline preparation, **Edit offline…** starts from the selected model’s factory scene. You can export it to Files. Choose **App → Mixer** when you intend to write that working scene to the console.

## Controls

- **Mixer and Channel** cover the 16 input strips, aux and FX returns, buses, DCAs, main LR, sends on faders, stereo links, preamps, key listen, EQ, gate and dynamics. XR12 has 12 physical inputs and all 16 mix channels. Select a strip on the mixer to open the same strip in the channel editor.
- **Effects and Meters** provide four slots with 61 effect types, preset import/export, algorithm-specific meters, gain reduction, monitor and DCA levels, and RTA.
- **Routing and Scenes** provide model-specific patching, twelve desktop routing presets, six routing recall scopes, scene files, channel presets, scoped copy/paste, and 64 mixer snapshot slots with recall scope and safes.
- **Setup** includes global audio, MIDI and network settings. On recorder models it also includes USB folder navigation, stereo recording sources and taps, transport, file selection, time and levels.
- The iPhone places Routing, Meters and Setup under **Tools**. The iPad shows these sections in the sidebar. With an iPad keyboard, Command-1 through Command-7 select the seven sections. The Mixer, Channel and Recorder menus list the other shortcuts.

## Build and verify

To run from source, open `XAirModern.xcodeproj`, select the **XAirModern** scheme and run it on an iPhone or iPad simulator. Regenerate the project with `xcodegen generate` after editing `project.yml`. The verification devices used Xcode 27.2 and the iOS 26.5 simulator runtime. Run the following commands from the project directory.

```sh
swift test --package-path Packages/XAirKit

xcodebuild test -project XAirModern.xcodeproj -scheme XAirModern \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO -derivedDataPath build/DerivedData

xcodebuild test -project XAirModern.xcodeproj -scheme XAirModern \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5' \
  -parallel-testing-enabled NO -derivedDataPath build/DerivedData
```

The core tests exercise OSC, model rules, sync and reconnect, read-back after writes, scope masks, desktop-generated preset fixtures, meter register layouts, recorder state and the fake firmware updater. The UI suite exercises live mute and EQ edits, routing presets, USB folders and playback, channel selection, FX changes in landscape, and accessibility audits on the mixer and channel editor.

Fresh screenshots of all seven sections can be generated with `tools/screenshots.sh XR18`. Supply a tab name to capture a single section, for example `tools/screenshots.sh XR12 mixer`. The UI tests attach screenshots after the routing, recorder and effects workflows.

## Verified 20 November 2026

| Target | Result |
|---|---|
| XAirKit on macOS | All 57 core tests passed |
| iPhone 17 Pro on iOS 26.5 | 57 core and 8 UI tests passed, zero skipped |
| iPad Pro 13-inch (M5) on iPadOS 26.5 | 57 core and 8 UI tests passed, zero skipped |
| Generic iOS device | Release build succeeded for ARM64 with code signing disabled |

The mixer and channel EQ passed the automated Dynamic Type, element description, hit region and element detection audits on both simulators. The iPad test selected Ch 02 and opened its editor using Command-2. The recorder test opened a folder, played a track, paused it, stepped to the next file and returned to the parent folder.

| Screen | iPhone | iPad |
|---|---|---|
| Mixer | [Light](screenshots/iphone-mixer-XR18.png) · [Dark](screenshots/iphone-mixer-dark.png) | [Light](screenshots/ipad-mixer-XR18.png) · [Dark](screenshots/ipad-mixer-dark.png) |
| Selected channel EQ | [iPhone](screenshots/iphone-channel-eq.png) | [iPad](screenshots/ipad-channel-eq.png) |
| Applied USB return preset | [iPhone](screenshots/iphone-routing-preset.png) | [iPad](screenshots/ipad-routing-preset.png) |
| XR12 recorder | [iPhone](screenshots/iphone-recorder-playback.png) | [iPad](screenshots/ipad-recorder-playback.png) |
| Precision Limiter in landscape | [iPhone](screenshots/iphone-effect-limiter-landscape.png) | [iPad](screenshots/ipad-effect-limiter-landscape.png) |

## Signing a build from Xcode

1. Choose your signing team and a bundle identifier you own in the XAirModern target. The checked-in identifier is `com.example.XAirModern`.
2. Allow **Local Network** access when prompted. It can be re-enabled in Settings under **Privacy & Security → Local Network**. [Apple local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
3. Broadcast discovery uses UDP 10024. The project declares Apple’s multicast networking entitlement. To sign with that entitlement, request it for your team, enable it for the App ID and regenerate the provisioning profile. A build signed without this capability can still connect by manual IP with local-network permission. [Apple multicast networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)

Physical sign-off requires the two hardware families. An X18/XR18-family console is needed for the multichannel USB interface and Ultranet, and an XR12/XR16-family console for the USB-stick recorder. Real preamps and phantom power, audible DSP, live meter accuracy, persistent snapshots, removable media and Wi-Fi reconnection remain unverified. The firmware transfer was exercised exclusively against a fake UDP updater. [Field checks](FEATURE_PARITY.md#verification-and-remaining-field-work)

## Project layout

| Path | Contents |
|---|---|
| `App/Sources` | SwiftUI screens, touch and keyboard controls, device settings |
| `Packages/XAirKit` | OSC and UDP, schema, session, simulator, files and firmware transfer |
| `Packages/XAirKit/Sources/XAirKit/Resources` | Parameter schema, desktop default scene, built-in routing and EQ presets |
| `Packages/XAirKit/Tests/XAirKitTests` and `UITests` | Core and end-to-end test suites |
| `research` and `tools` | Desktop evidence, parameter and preset extraction, screenshot script |
| `screenshots` | Native iPhone and iPad captures |

## License

Aayush Ale licenses the original XAirModern code, tools, documentation and artwork under the MIT License. [License text](LICENSE)

The XAirKit resource files, desktop-generated test fixtures and tables in `research/runtime-dumps/` contain interoperability data derived from Behringer X-AIR-Edit 1.8.1. Any third-party rights in those materials and product names belong to their respective owners. [Data provenance](PROTOCOL.md)
