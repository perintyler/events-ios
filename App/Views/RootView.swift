import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
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
