import Foundation

/// What to post for a page of freshly-fetched events: a few individual banners,
/// and one summary standing in for the rest.
struct Announcement: Equatable {
    /// Events that get a banner of their own, newest first.
    let banners: [BarryEvent]
    /// How many unseen events were left out of `banners`. Zero means every one
    /// of them got a banner.
    let overflowCount: Int

    static let none = Announcement(banners: [], overflowCount: 0)

    var isEmpty: Bool { banners.isEmpty && overflowCount == 0 }

    var summaryBody: String? {
        guard overflowCount > 0 else { return nil }
        return "+\(overflowCount) more event\(overflowCount == 1 ? "" : "s")"
    }
}

/// Decides which events deserve a notification, with no reference to
/// `UNUserNotificationCenter` — that class cannot be exercised in a unit test,
/// so the rules that decide *whether to alert at all* live here instead, where
/// they can be.
enum EventAnnouncement {
    /// Beyond this many new events at once, collapse the rest into one summary
    /// notification instead of stacking a wall of banners.
    static let individualLimit = 3

    /// - Parameters:
    ///   - page: the newest page, newest first, exactly as the server returned it.
    ///   - lastNotifiedAt: the newest event already announced. `nil` means the
    ///     app has not announced anything yet in this launch, and nothing is
    ///     announced — the first page is a backlog the user never asked to be
    ///     told about, and announcing it would fire a banner for every event in
    ///     the feed on launch.
    ///   - isFeedOnScreen: true when the user is looking at the feed right now.
    ///     Banner-ing a row that is already visible is noise, so the mark still
    ///     advances but nothing is posted.
    static func decide(
        page: [BarryEvent],
        lastNotifiedAt: Date?,
        isFeedOnScreen: Bool
    ) -> Announcement {
        guard let mark = lastNotifiedAt, !isFeedOnScreen else { return .none }

        let unseen = page.filter { $0.createdAt > mark && $0.isUnread }
        guard !unseen.isEmpty else { return .none }

        return Announcement(
            banners: Array(unseen.prefix(individualLimit)),
            overflowCount: max(0, unseen.count - individualLimit)
        )
    }

    /// The high-water mark after seeing this page.
    ///
    /// Advances on EVERY refresh, including the suppressed ones: an event the
    /// user watched arrive on screen must not be announced later just because
    /// they backgrounded the app before the next poll.
    static func advanceMark(_ mark: Date?, over page: [BarryEvent]) -> Date? {
        guard let newest = page.map(\.createdAt).max() else { return mark }
        guard let mark else { return newest }
        return max(mark, newest)
    }
}
