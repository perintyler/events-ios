import XCTest
@testable import Events

/// The feed is dominated by repeats — a 100-event sample from the live API held
/// only 22 distinct titles, one of them 40 times. These pin the folding that
/// makes it readable, and the guarantee that folding never hides anything.
@MainActor
final class FeedGroupingTests: XCTestCase {

    private func event(
        id: String,
        title: String,
        type: EventType = .systemAlert,
        severity: Severity = .warn,
        unread: Bool = true,
        secondsAgo: TimeInterval = 0
    ) -> BarryEvent {
        BarryEvent(
            id: id, type: type, sessionId: nil, source: "cli",
            title: title, body: nil, severity: severity,
            data: [:], metadata: [:], deliveredVia: [],
            readAt: unread ? nil : Date(),
            createdAt: Date(timeIntervalSince1970: 1_789_539_535 - secondsAgo)
        )
    }

    /// Digits vary between repeats of the same alert; everything else does not.
    func testRecurrenceKeyIgnoresNumbers() {
        let a = event(id: "1", title: ":warning: *Barry* MCP transports at 64% of the ceiling")
        let b = event(id: "2", title: ":warning: *Barry* MCP transports at 71% of the ceiling")
        XCTAssertEqual(a.recurrenceKey, b.recurrenceKey)
    }

    /// A recovery notice is NOT the same event as the alert it recovers from,
    /// even though the rest of the sentence matches.
    func testRecoveryIsNotFoldedIntoItsAlert() {
        let alert = event(id: "1", title: ":warning: *Barry* MCP transports at 64% of the ceiling")
        let recovered = event(id: "2", title: ":white_check_mark: *Barry Recovered* MCP transports at 64% of the ceiling")
        XCTAssertNotEqual(alert.recurrenceKey, recovered.recurrenceKey)
    }

    func testDifferentSeveritiesDoNotFold() {
        let warn = event(id: "1", title: "Host swap in use: 900MB", severity: .warn)
        let error = event(id: "2", title: "Host swap in use: 950MB", severity: .error)
        XCTAssertNotEqual(warn.recurrenceKey, error.recurrenceKey)
    }

    func testGroupingOffShowsEveryRow() {
        let store = AppStore(config: .init(baseURL: "http://127.0.0.1:1", hostHeader: "", secret: ""))
        store.groupRepeats = false
        store.setEventsForTesting([
            event(id: "1", title: "MCP transports at 64% of the ceiling"),
            event(id: "2", title: "MCP transports at 65% of the ceiling"),
        ])
        XCTAssertEqual(store.displayRows.count, 2)
        XCTAssertTrue(store.displayRows.allSatisfy { $0.repeatCount == 1 })
    }

    func testConsecutiveRepeatsFoldWithACount() {
        let store = AppStore(config: .init(baseURL: "http://127.0.0.1:1", hostHeader: "", secret: ""))
        store.groupRepeats = true
        store.setEventsForTesting([
            event(id: "1", title: "MCP transports at 64% of the ceiling"),
            event(id: "2", title: "MCP transports at 65% of the ceiling"),
            event(id: "3", title: "MCP transports at 66% of the ceiling"),
            event(id: "4", title: "Host swap in use: 900MB"),
        ])
        let rows = store.displayRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].repeatCount, 3)
        XCTAssertEqual(rows[1].repeatCount, 1)
    }

    /// Non-adjacent repeats stay separate: folding across a gap would reorder
    /// the feed and misreport when the run actually happened.
    func testOnlyConsecutiveRepeatsFold() {
        let store = AppStore(config: .init(baseURL: "http://127.0.0.1:1", hostHeader: "", secret: ""))
        store.groupRepeats = true
        store.setEventsForTesting([
            event(id: "1", title: "MCP transports at 64% of the ceiling"),
            event(id: "2", title: "Host swap in use: 900MB"),
            event(id: "3", title: "MCP transports at 66% of the ceiling"),
        ])
        XCTAssertEqual(store.displayRows.count, 3)
    }

    /// A fold whose head is read would look settled while unread repeats hide
    /// beneath it — the head must surface the unread one.
    func testFoldSurfacesAnUnreadRepeat() {
        let store = AppStore(config: .init(baseURL: "http://127.0.0.1:1", hostHeader: "", secret: ""))
        store.groupRepeats = true
        store.setEventsForTesting([
            event(id: "1", title: "MCP transports at 64% of the ceiling", unread: false),
            event(id: "2", title: "MCP transports at 65% of the ceiling", unread: true),
        ])
        let row = try? XCTUnwrap(store.displayRows.first)
        XCTAssertEqual(row?.repeatCount, 2)
        XCTAssertEqual(row?.event.isUnread, true, "the fold is hiding an unread event behind a read one")
    }

    /// Grouping is a DISPLAY concern. It must never change the unread count,
    /// or the badge would disagree with the server about how much is unread.
    func testGroupingDoesNotChangeTheUnreadCount() {
        let store = AppStore(config: .init(baseURL: "http://127.0.0.1:1", hostHeader: "", secret: ""))
        store.setEventsForTesting([
            event(id: "1", title: "MCP transports at 64% of the ceiling"),
            event(id: "2", title: "MCP transports at 65% of the ceiling"),
            event(id: "3", title: "MCP transports at 66% of the ceiling"),
        ])
        store.setUnreadCountForTesting(1355)

        store.groupRepeats = false
        let ungrouped = store.unreadCount
        store.groupRepeats = true
        XCTAssertEqual(store.unreadCount, ungrouped)
        XCTAssertEqual(store.unreadCount, 1355)
        XCTAssertLessThan(store.displayRows.count, 3, "precondition: these should have folded")
    }
}
