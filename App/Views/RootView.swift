import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var notifier: Notifier
    @State private var showingSettings = false
    /// Driven so a tapped notification can push its event's detail view.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            FeedView()
                .navigationTitle("Events")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier("settingsButton")
                    }
                    ToolbarItem(placement: .topBarTrailing) { FilterMenu() }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack { SettingsView() }
                }
        }
        // Polling lives above the list so it survives navigation into a detail
        // view and back.
        .task { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: notifier.tappedEventId) { _, id in
            guard let id else { return }
            notifier.tappedEventId = nil
            // The detail view resolves the id against loaded events, so a tap on
            // a notification for something scrolled out of memory lands on the
            // feed rather than a blank screen.
            path.append(id)
        }
    }
}

struct FilterMenu: View {
    @EnvironmentObject private var store: AppStore

    private var isFiltered: Bool {
        store.typeFilter != nil || store.severityFilter != nil || store.unreadOnly
    }

    var body: some View {
        Menu {
            Toggle("Unread only", isOn: $store.unreadOnly)
            Toggle("Group repeats", isOn: $store.groupRepeats)

            Picker("Type", selection: $store.typeFilter) {
                Text("Any type").tag(EventType?.none)
                ForEach(EventType.filterable, id: \.wireValue) { type in
                    Text(type.label.capitalized).tag(EventType?.some(type))
                }
            }

            Picker("Severity", selection: $store.severityFilter) {
                Text("Any severity").tag(Severity?.none)
                ForEach(Severity.allCases, id: \.self) { severity in
                    Text(severity.rawValue.capitalized).tag(Severity?.some(severity))
                }
            }

            if isFiltered {
                Divider()
                Button("Clear filters", role: .destructive) {
                    store.typeFilter = nil
                    store.severityFilter = nil
                    store.unreadOnly = false
                }
            }
        } label: {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                         : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("filterMenu")
    }
}
