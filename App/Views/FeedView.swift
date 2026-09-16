import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingMarkAll = false

    var body: some View {
        List {
            if let error = store.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                ForEach(store.displayRows) { row in
                    NavigationLink(value: row.event.id) {
                        EventRow(event: row.event, repeatCount: row.repeatCount)
                    }
                    .onAppear {
                        // Paginate when the tail comes into view.
                        if row.id == store.displayRows.last?.id {
                            Task { await store.loadMore() }
                        }
                    }
                }

                if store.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } header: {
                header
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading && store.events.isEmpty {
                ProgressView()
            } else if store.hasLoadedOnce && store.events.isEmpty {
                // Deliberately distinct from the error state: "nothing matched"
                // and "could not reach the server" are different problems.
                ContentUnavailableView(
                    "No events",
                    systemImage: "tray",
                    description: Text(store.loadError == nil
                        ? "Nothing matches these filters."
                        : "Could not load the feed.")
                )
            }
        }
        .navigationDestination(for: String.self) { id in
            if let event = store.events.first(where: { $0.id == id }) {
                EventDetailView(event: event)
            }
        }
        .confirmationDialog(
            markAllPrompt,
            isPresented: $confirmingMarkAll,
            titleVisibility: .visible
        ) {
            Button("Mark read", role: .destructive) {
                Task { await store.markAllRead() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if store.markAllReadIsGlobal {
                Text("The server can only clear everything, or everything of one type — "
                     + "the severity and unread filters are not applied to this action.")
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(store.unreadCount) unread")
                .accessibilityIdentifier("unreadCount")
            Spacer()
            if store.unreadCount > 0 {
                Button("Mark all read") { confirmingMarkAll = true }
                    .font(.caption)
                    .accessibilityIdentifier("markAllReadButton")
            }
        }
    }

    /// Names the scope the action ACTUALLY has. `markAllRead` on the server
    /// honours only `type`, so with a severity or unread filter on screen the
    /// prompt must say "all", never "these".
    private var markAllPrompt: String {
        if let type = store.typeFilter {
            return "Mark all \(type.label.lowercased()) events read?"
        }
        return "Mark all \(store.unreadCount) events read?"
    }
}

struct EventRow: View {
    let event: BarryEvent
    var repeatCount: Int = 1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Theme.tint(for: event.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .opacity(event.isUnread ? 1 : 0.25)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.summaryLine)
                    .font(.subheadline)
                    .fontWeight(event.isUnread ? .semibold : .regular)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if repeatCount > 1 {
                        Text("×\(repeatCount)")
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.tint(for: event.severity))
                    }
                    Text(event.type.label)
                        .foregroundStyle(Theme.tint(for: event.type))
                    if let phase = event.phase {
                        Text("· \(phase)")
                    }
                    Text("· \(event.source)")
                    Spacer()
                    Text(Theme.relativeAge(event.createdAt))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
