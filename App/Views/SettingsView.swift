import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = ""
    @State private var hostHeader: String = ""
    @State private var secret: String = ""
    @State private var probeResult: String?
    @State private var probeOK = false
    @State private var isProbing = false

    var body: some View {
        Form {
            Section {
                TextField("http://100.x.x.x", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURLField")
                TextField("Host header (e.g. barry.lan)", text: $hostHeader)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("hostHeaderField")
                SecureField("BARRY_SECRET (optional on the tailnet)", text: $secret)
                    .accessibilityIdentifier("secretField")
            } header: {
                Text("Server")
            } footer: {
                Text("The Mac's Tailscale address. It CHANGES — find the current one "
                     + "with `tailscale ip -4`. The host header routes the request "
                     + "through Caddy; the raw service port is not reachable.")
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
                .accessibilityIdentifier("testConnectionButton")

                if let probeResult {
                    Label(probeResult, systemImage: probeOK ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(probeOK ? .green : .red)
                        .font(.footnote)
                        .accessibilityIdentifier("probeResult")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    store.updateConfig(
                        ServerConfig(baseURL: baseURL, hostHeader: hostHeader, secret: secret)
                    )
                    dismiss()
                }
            }
        }
        .onAppear {
            baseURL = store.config.baseURL
            hostHeader = store.config.hostHeader
            secret = store.config.secret
        }
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }
        let candidate = ServerConfig(baseURL: baseURL, hostHeader: hostHeader, secret: secret)
        do {
            try await EventsClient(config: candidate).probe()
            probeOK = true
            probeResult = "Connected."
        } catch {
            probeOK = false
            probeResult = error.localizedDescription
        }
    }
}
