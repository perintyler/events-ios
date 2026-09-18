import SwiftUI

@main
struct EventsApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.notifier)
                .task {
                    store.notifier.requestAuthorization()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // `.active` is the only phase where the user can actually read the
            // feed. `.inactive` covers the app switcher and the moment a banner
            // is pulled down — announcing then is what makes this useful at all,
            // since the poll keeps running for a short while after backgrounding.
            store.isFeedOnScreen = phase == .active
            if phase == .active {
                Task { await store.notifier.refreshAuthorizationState() }
            }
        }
    }
}
