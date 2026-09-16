import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject private var store: AppStore
    let event: BarryEvent

    var body: some View {
        List {
            Section {
                Text(event.displayTitle)
                    .font(.subheadline)
                    .textSelection(.enabled)
                if let body = event.body, !body.isEmpty {
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Event") {
                pair("Type", event.type.label)
                pair("Severity", event.severity.rawValue)
                pair("Source", event.source)
                if let phase = event.phase { pair("Phase", phase) }
                if let session = event.sessionId { pair("Session", session) }
                pair("Created", Theme.timestamp.string(from: event.createdAt))
                pair("Read", event.readAt.map(Theme.timestamp.string(from:)) ?? "Unread")
                // Empty is the norm on this deployment — say so, rather than
                // rendering a blank row that looks like a rendering bug.
                pair("Delivered via",
                     event.deliveredVia.isEmpty ? "Not delivered" : event.deliveredVia.joined(separator: ", "))
            }

            if !event.detailPairs.isEmpty {
                Section("Data") {
                    ForEach(event.detailPairs, id: \.key) { pair($0.key, $0.value) }
                }
            }

            if !event.metadataPairs.isEmpty {
                Section("Metadata") {
                    ForEach(event.metadataPairs, id: \.key) { pair($0.key, $0.value) }
                }
            }

            if event.isUnread {
                Section {
                    Button("Mark read") {
                        Task { await store.markRead(event) }
                    }
                    .accessibilityIdentifier("markReadButton")
                }
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pair(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }
}
