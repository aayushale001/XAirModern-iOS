import SwiftUI
import XAirKit

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.session.state {
            case .online, .syncing, .reconnecting:
                MainView().disabled(app.session.state != .online)
            default:
                if app.offlineEditing { MainView() } else { ConnectView() }
            }
        }
        // Keep the display awake while controlling a mixer (iOS equivalent of the original's "no App Nap").
        .onChange(of: app.session.state.isConnected, initial: true) { _, connected in
            UIApplication.shared.isIdleTimerDisabled = connected
        }
        .onChange(of: app.isOnline) { _, online in
            if online { app.rememberConnectedMixer() }
        }
        .overlay(alignment: .top) { StatusBanner() }
        .alert(item: $app.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

/// Connection status banner (syncing progress, reconnecting, errors).
struct StatusBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.session.state {
        case .syncing:
            HStack(spacing: 10) {
                ProgressView(value: app.session.syncProgress).frame(width: 120)
                Text("Synchronizing \(Int(app.session.syncProgress * 100))%").font(.footnote.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        case .reconnecting(let ip):
            Label("Lost connection – reconnecting to \(ip)…", systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.tint(.orange.opacity(0.4)), in: .capsule)
                .padding(.top, 4)
        default:
            if app.offlineEditing {
                Label("Offline editing · \(app.model.displayName)", systemImage: "icloud.slash")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular.tint(.gray.opacity(0.3)), in: .capsule)
                    .padding(.top, 4)
            }
        }
    }
}
