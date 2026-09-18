import Foundation
import SwiftUI

/// Where the "group repeats" toggle persists. File-scope because a stored
/// property initializer cannot reference `Self`.
let groupRepeatsDefaultsKey = "feed.groupRepeats"

/// App-wide state: server config, the feed, filters, connectivity.
///
/// REST-poll only. There IS a topic bus at `/api/v1/ws` that the web feed and
/// the macOS app subscribe to for `"events"` — but nothing in the server ever
/// publishes that topic (the only non-test `publishToTopic` call sites publish
/// `"identities"`). A subscription would connect and then stay silent forever,
/// which is indistinguishable from "nothing is happening". Polling is therefore
/// the source of truth here, deliberately, rather than an optimisation to
/// replace later.
@MainActor
final class AppStore: ObservableObject {
    @Published var config: ServerConfig
    @Published private(set) var events: [BarryEvent] = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadError: String?
    /// True once a page has come back, so an empty feed can say "no events"
    /// instead of showing a spinner forever.
    @Published private(set) var hasLoadedOnce = false

    @Published var typeFilter: EventType? { didSet { if typeFilter != oldValue { resetAndReload() } } }
    @Published var severityFilter: Severity? { didSet { if severityFilter != oldValue { resetAndReload() } } }
    @Published var unreadOnly: Bool = false { didSet { if unreadOnly != oldValue { resetAndReload() } } }

    /// Collapse consecutive repeats of the same alert into one row.
    ///
    /// Purely a display concern — nothing is filtered out server-side and the
    /// unread count is untouched, so this cannot hide an event from the count
    /// that says how many there are. Off by default: a reader should not
    /// silently omit rows until the user asks it to.
    ///
    /// `@Published` + manual persistence rather than `@AppStorage`: an
    /// `@AppStorage` property on an ObservableObject does NOT fire
    /// `objectWillChange`, so flipping the toggle rewrote the preference and
    /// left the feed rendering ungrouped. Found by screenshotting the running
    /// app with the preference already set to true — the unit tests could not
    /// see it, because they set the property and read `displayRows` in the same
    /// breath, which never needs a republish.
    @Published var groupRepeats: Bool = UserDefaults.standard.bool(forKey: groupRepeatsDefaultsKey) {
        didSet { UserDefaults.standard.set(groupRepeats, forKey: groupRepeatsDefaultsKey) }
    }


    /// The feed as rendered: either every event, or consecutive repeats folded
    /// into one row carrying a count.
    var displayRows: [FeedRow] {
        guard groupRepeats else { return events.map { FeedRow(event: $0, repeatCount: 1) } }
        var rows: [FeedRow] = []
        for event in events {
            if var last = rows.last, last.event.recurrenceKey == event.recurrenceKey {
                last.repeatCount += 1
                // Keep the NEWEST unread state visible: a fold whose head is
                // read would look settled while unread repeats hide beneath it.
                if event.isUnread && !last.event.isUnread { last.event = event }
                rows[rows.count - 1] = last
            } else {
                rows.append(FeedRow(event: event, repeatCount: 1))
            }
        }
        return rows
    }

    private var nextCursor: String?
    private var pollTimer: Timer?

    /// The server's own default page size; its maximum is 100.
    private let pageSize = 50
    /// Matches barry-iphone's list cadence.
    private let pollInterval: TimeInterval = 12

    var client: EventsClient { EventsClient(config: config) }

    /// Local notifications for events that arrive while the feed is not on
    /// screen. Owned here because `refresh` is the only thing that ever learns
    /// an event is new.
    let notifier = Notifier()

    /// Whether the user can see the feed right now. Notifications are
    /// suppressed while true — banner-ing a row already on screen is noise.
    /// `RootView` drives this from the scene phase.
    var isFeedOnScreen = true

    /// Whether "mark all read" would reach beyond what is on screen. True
    /// whenever a filter the server ignores is active — see `markAllRead`.
    var markAllReadIsGlobal: Bool { severityFilter != nil || unreadOnly }

    init(config: ServerConfig = .load()) {
        self.config = config
    }

    func updateConfig(_ newConfig: ServerConfig) {
        config = newConfig
        newConfig.save()
        resetAndReload()
    }

    // MARK: - Lifecycle

    func start() {
        if events.isEmpty { Task { await refresh() } }
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(silently: true) }
        }
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Loading

    private func resetAndReload() {
        events = []
        nextCursor = nil
        hasLoadedOnce = false
        Task { await refresh() }
    }

    /// Refresh page one and the unread count.
    ///
    /// `silently` suppresses the spinner and the error banner for background
    /// polls, so a transient blip while the phone changes networks does not
    /// replace a screen full of readable events with an error.
    func refresh(silently: Bool = false) async {
        if !silently && events.isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let page = try await client.events(
                limit: pageSize,
                type: typeFilter,
                severity: severityFilter,
                unreadOnly: unreadOnly
            )
            merge(page.events)
            notifier.announce(page: page.events, isFeedOnScreen: isFeedOnScreen)
            // Only advance the cursor from a fresh first page; otherwise a poll
            // would rewind pagination the user has already scrolled past.
            if events.count <= pageSize { nextCursor = page.nextCursor }
            hasLoadedOnce = true
            loadError = nil
        } catch {
            if !silently { loadError = error.localizedDescription }
        }

        await refreshUnreadCount()
    }

    /// The unread badge comes from the server's own count, NEVER from counting
    /// loaded rows: the backlog is four figures while a page is 50, so counting
    /// what is in memory would confidently display "50" and look plausible.
    private func refreshUnreadCount() async {
        if let count = try? await client.unreadCount() { unreadCount = count }
    }

    /// Append the next page.
    ///
    /// Guarded against the server's cursor behaviour: an undecodable cursor is
    /// IGNORED and page one comes back with HTTP 200 (verified live). Without
    /// the "did this page add anything new" check below, that turns infinite
    /// scroll into an infinite loop appending duplicates forever.
    func loadMore() async {
        guard !isLoadingMore, !isLoading, let cursor = nextCursor else { return }
        await loadMore(usingCursor: cursor)
    }

    /// Seam for tests: drive the paging path with a chosen cursor, so the
    /// zero-new-ids guard can be exercised against a cursor the server REJECTS.
    /// Without this the guard is unreachable from a test — the real cursor
    /// always works, so removing the guard left every test green.
    func loadMore(usingCursor cursor: String) async {
        guard !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await client.events(
                limit: pageSize,
                cursor: cursor,
                type: typeFilter,
                severity: severityFilter,
                unreadOnly: unreadOnly
            )
            let known = Set(events.map(\.id))
            let fresh = page.events.filter { !known.contains($0.id) }

            guard !fresh.isEmpty else {
                // Either genuinely the end, or a cursor the server rejected and
                // silently replaced with page one. Both mean "stop paging".
                nextCursor = nil
                return
            }
            events.append(contentsOf: fresh)
            nextCursor = page.nextCursor
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Merge a fresh first page into the list by id, preserving order and any
    /// later pages already loaded, so a background poll does not reset scroll.
    private func merge(_ incoming: [BarryEvent]) {
        guard !events.isEmpty else {
            events = incoming
            return
        }
        var byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var order = events.map(\.id)
        let known = Set(order)

        // New events are newer than everything held, so they go on top in the
        // order the server returned them.
        let newcomers = incoming.filter { !known.contains($0.id) }
        for event in incoming { byId[event.id] = event }
        order.insert(contentsOf: newcomers.map(\.id), at: 0)

        events = order.compactMap { byId[$0] }
    }

    // MARK: - Test seams

    /// Populate the feed without a server, so display logic (grouping, ordering)
    /// can be tested without standing up a fixture API.
    func setEventsForTesting(_ list: [BarryEvent]) { events = list }
    func setUnreadCountForTesting(_ count: Int) { unreadCount = count }

    // MARK: - Writes

    func markRead(_ event: BarryEvent) async {
        guard event.isUnread else { return }
        // Optimistic: the row updates immediately, and the count is corrected
        // from the server rather than guessed at.
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = events[index].markingRead()
        }
        unreadCount = max(0, unreadCount - 1)
        do {
            try await client.markRead(event.id)
        } catch {
            loadError = error.localizedDescription
        }
        await refreshUnreadCount()
    }

    /// Mark everything read.
    ///
    /// Only the type filter is passed, because it is the only one the server
    /// honours — `markAllRead` in packages/db ignores severity, session and
    /// unread. Callers must confirm with the true scope first; see
    /// `markAllReadIsGlobal`.
    func markAllRead() async {
        do {
            _ = try await client.markAllRead(type: typeFilter)
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
