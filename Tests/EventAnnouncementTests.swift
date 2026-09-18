import XCTest
@testable import Events

/// What the user actually experiences from notifications: how many banners they
/// get, whether a quiet feed stays quiet, and whether backgrounding the app
/// re-announces things they have already seen.
///
/// These test `EventAnnouncement` rather than the `Notifier` that wraps it,
/// because `UNUserNotificationCenter` cannot run under XCTest — so every rule
/// that decides *whether to alert* is deliberately outside it.
final class EventAnnouncementTests: XCTestCase {

    private let mark = Date(timeIntervalSince1970: 1_789_539_535)

    private func event(
        id: String,
        secondsAfterMark: TimeInterval,
        unread: Bool = true,
        severity: Severity = .info
    ) -> BarryEvent {
        BarryEvent(
            id: id, type: .notification, sessionId: nil, source: "cli",
            title: "event \(id)", body: nil, severity: severity,
            data: [:], metadata: [:], deliveredVia: [],
            readAt: unread ? nil : Date(),
            createdAt: mark.addingTimeInterval(secondsAfterMark)
        )
    }

    func testQuietFeedAnnouncesNothing() {
        let decision = EventAnnouncement.decide(
            page: [event(id: "old", secondsAfterMark: -30)],
            lastNotifiedAt: mark,
            isFeedOnScreen: false
        )
        XCTAssertEqual(decision, .none)
        XCTAssertNil(decision.summaryBody)
    }

    /// Five at once must not be five banners. Three, then one line saying how
    /// much was left out.
    func testFiveNewEventsBecomeThreeBannersAndASummary() {
        let page = (1...5).map { event(id: "\($0)", secondsAfterMark: TimeInterval(60 - $0)) }
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: mark, isFeedOnScreen: false)

        XCTAssertEqual(decision.banners.count, 3)
        XCTAssertEqual(decision.banners.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(decision.overflowCount, 2)
        XCTAssertEqual(decision.summaryBody, "+2 more events")
    }

    /// Exactly the limit gets no summary — "+0 more" is a notification that
    /// tells the user nothing.
    func testExactlyTheLimitGetsNoSummary() {
        let page = (1...3).map { event(id: "\($0)", secondsAfterMark: TimeInterval($0)) }
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: mark, isFeedOnScreen: false)

        XCTAssertEqual(decision.banners.count, 3)
        XCTAssertEqual(decision.overflowCount, 0)
        XCTAssertNil(decision.summaryBody)
    }

    func testOneOverflowSaysEventNotEvents() {
        let page = (1...4).map { event(id: "\($0)", secondsAfterMark: TimeInterval($0)) }
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: mark, isFeedOnScreen: false)
        XCTAssertEqual(decision.summaryBody, "+1 more event")
    }

    /// An event read elsewhere (the web feed, the Mac) is not news on the phone.
    func testAlreadyReadEventsAreNeverAnnounced() {
        let page = [
            event(id: "read", secondsAfterMark: 20, unread: false),
            event(id: "unread", secondsAfterMark: 10),
        ]
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: mark, isFeedOnScreen: false)
        XCTAssertEqual(decision.banners.map(\.id), ["unread"])
    }

    /// The poll refetches the whole first page every 12 seconds. Without the
    /// high-water mark that would re-announce fifty events, five times a minute.
    func testEventsOlderThanTheMarkAreNeverReAnnounced() {
        let page = [
            event(id: "new", secondsAfterMark: 5),
            event(id: "seen", secondsAfterMark: -5),
            event(id: "older", secondsAfterMark: -500),
        ]
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: mark, isFeedOnScreen: false)
        XCTAssertEqual(decision.banners.map(\.id), ["new"])
        XCTAssertEqual(decision.overflowCount, 0)
    }

    /// The user is looking at the row. A banner for it is noise.
    func testNothingIsAnnouncedWhileTheFeedIsOnScreen() {
        let page = (1...5).map { event(id: "\($0)", secondsAfterMark: TimeInterval($0)) }
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: mark, isFeedOnScreen: true)
        XCTAssertEqual(decision, .none)
    }

    /// Launch loads a backlog of thousands. None of it is news.
    func testTheFirstPageEverLoadedIsNotAnnounced() {
        let page = (1...5).map { event(id: "\($0)", secondsAfterMark: TimeInterval($0)) }
        let decision = EventAnnouncement.decide(page: page, lastNotifiedAt: nil, isFeedOnScreen: false)
        XCTAssertEqual(decision, .none)
    }

    func testTheMarkIsSetByTheFirstPageSoLaterPollsHaveSomethingToCompareAgainst() {
        let page = [event(id: "newest", secondsAfterMark: 30), event(id: "older", secondsAfterMark: 10)]
        XCTAssertEqual(EventAnnouncement.advanceMark(nil, over: page), mark.addingTimeInterval(30))
    }

    /// An event watched arriving on screen must not be announced later just
    /// because the app was backgrounded before the next poll — so the mark
    /// advances even on the refreshes that announce nothing.
    func testTheMarkAdvancesPastEventsSeenOnScreen() {
        let seenOnScreen = [event(id: "watched", secondsAfterMark: 40)]
        let advanced = EventAnnouncement.advanceMark(mark, over: seenOnScreen)

        let decision = EventAnnouncement.decide(
            page: seenOnScreen,
            lastNotifiedAt: advanced,
            isFeedOnScreen: false
        )
        XCTAssertEqual(decision, .none, "an event already seen on screen was announced after backgrounding")
    }

    /// The server returns newest-first; an older page must never drag the mark
    /// backwards and re-announce everything after it.
    func testTheMarkNeverGoesBackwards() {
        let older = [event(id: "older", secondsAfterMark: -100)]
        XCTAssertEqual(EventAnnouncement.advanceMark(mark, over: older), mark)
    }

    func testAnEmptyPageLeavesTheMarkAlone() {
        XCTAssertEqual(EventAnnouncement.advanceMark(mark, over: []), mark)
    }
}
