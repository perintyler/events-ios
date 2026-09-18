import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var notifier: Notifier
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = ""
    @State private var secret: String = ""
    @State private var outcome: ProbeOutcome?
    @State private var isProbing = false

    var body: some View {
        Form {
            Section {
                TextField(ServerConfig.defaultDeviceURL, text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURLField")
                SecureField("BARRY_SECRET (required on the tailnet)", text: $secret)
                    .accessibilityIdentifier("secretField")
            } header: {
                Text("Server")
            } footer: {
                Text("On a phone the app reaches the Mac over the tailnet at "
                     + "\(ServerConfig.defaultDeviceURL). The secret is required "
                     + "there — the server rejects an unauthenticated request.")
            }

            Section {
                Button {
                    Task { await probe() }
                } label: {
                    HStack {
                        Text("Test connection")
                        if isProbing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isProbing)
                .accessibilityIdentifier("testConnectionButton")

                if let outcome {
                    Label {
                        Text(outcome.message)
                    } icon: {
                        Image(systemName: icon(for: outcome))
                    }
                    .foregroundStyle(tint(for: outcome))
                    .font(.footnote)
                    .accessibilityIdentifier("probeResult")
                }
            } footer: {
                Text("Makes a real request. It tells apart a server that is not "
                     + "reachable from one that is reachable but refused the secret.")
            }

            // Only shown when there is something to fix. Authorization is per
            // bundle identifier and changeable only in iOS Settings, so a
            // denial is otherwise indistinguishable from a quiet feed.
            if notifier.wasDenied {
                Section {
                    Button("Open iOS Settings") { notifier.openSystemSettings() }
                        .accessibilityIdentifier("openNotificationSettingsButton")
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Notifications are turned off for Events, so new events "
                         + "will arrive silently. They only fire while the app is "
                         + "running either way — there is no push.")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    store.updateConfig(ServerConfig(baseURL: baseURL, secret: secret))
                    dismiss()
                }
            }
        }
        .onAppear {
            baseURL = store.config.baseURL
            secret = store.config.secret
        }
    }

    /// Three states, not two: a 403 proved the network path works, so it must
    /// not wear the same red X as a host that never answered.
    private func icon(for outcome: ProbeOutcome) -> String {
        if outcome.isFullyWorking { return "checkmark.circle" }
        return outcome.isReachable ? "exclamationmark.triangle" : "xmark.circle"
    }

    private func tint(for outcome: ProbeOutcome) -> Color {
        if outcome.isFullyWorking { return .green }
        return outcome.isReachable ? .orange : .red
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }
        let candidate = ServerConfig(baseURL: baseURL, secret: secret)
        outcome = await ConnectionProbe(config: candidate).run()
    }
}
