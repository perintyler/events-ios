import XCTest
@testable import Events

/// Integration tests against the REAL local API. No mocks.
///
/// They SKIP rather than fail when the server is unreachable, so a clone
/// without Barry running still gets a green unit suite — but note what that
/// costs: a skip and a pass look the same in a summary line. `scripts/test.sh`
/// probes the API first and says out loud which one you are getting.
final class LiveEventsAPITests: XCTestCase {

    private var client: EventsClient!

    override func setUp() async throws {
        try await super.setUp()
        let config = ServerConfig(
            baseURL: "http://127.0.0.1:9429", secret: ""
        )
        client = EventsClient(config: config)

        // Skip ONLY when the server is genuinely unreachable. An earlier version
        // skipped on any error, which meant a decoding bug silently disabled this
        // whole suite instead of failing it — the live tests went quiet at exactly
        // the moment they had something to report. Caught by the `ok`-field
        // negative control, which turned six live tests into skips.
        do {
            _ = try await client.events(limit: 1)
        } catch let error as EventsError {
            switch error {
            case .decoding, .http:
                throw error
            case .badURL:
                throw XCTSkip("misconfigured base URL")
            }
        } catch {
            throw XCTSkip("Barry API not reachable on 127.0.0.1:9429 — \(error.localizedDescription)")
        }
    }

    /// The live payload really does omit `ok`. If the server ever starts
    /// sending it again this still passes (extra keys are ignored) — the
    /// direction that breaks the app is a REQUIRED `ok`, which the unit test
    /// pins.
    func testListDecodesAgainstLiveServer() async throws {
        let page = try await client.events(limit: 5)
        XCTAssertFalse(page.events.isEmpty, "the feed has a large backlog; a page should not be empty")
        XCTAssertNotNil(page.nextCursor, "a full page should offer a cursor")
    }

    /// Keyset pagination: page two must not repeat page one.
    func testCursorAdvancesToDisjointPage() async throws {
        let first = try await client.events(limit: 5)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await client.events(limit: 5, cursor: cursor)

        let firstIds = Set(first.events.map(\.id))
        let secondIds = Set(second.events.map(\.id))
        XCTAssertFalse(secondIds.isEmpty)
        XCTAssertTrue(firstIds.isDisjoint(with: secondIds),
                      "page two repeated page one — pagination is not advancing")
    }

    /// The trap this app is designed around.
    ///
    /// `decodeEventCursor` returns nil for an undecodable cursor and the route
    /// then queries with no `before:` at all — so the server answers HTTP 200
    /// with page one. Nothing about the response says the cursor was rejected.
    /// Verified live before this app was written.
    func testGarbageCursorSilentlyReturnsFirstPage() async throws {
        let first = try await client.events(limit: 3)
        let garbage = try await client.events(limit: 3, cursor: "NOTBASE64!!")

        XCTAssertEqual(first.events.map(\.id), garbage.events.map(\.id),
                       "if this ever differs, the server learned to reject bad cursors "
                       + "and AppStore.loadMore's zero-new-ids guard can be revisited")
    }

    /// The guard that turns that trap into a stop instead of an infinite loop.
    @MainActor
    func testLoadMoreStopsWhenAPageAddsNothingNew() async throws {
        let store = AppStore(config: ServerConfig(
            baseURL: "http://127.0.0.1:9429", secret: ""
        ))
        await store.refresh()
        let afterFirst = store.events.count
        XCTAssertGreaterThan(afterFirst, 0)

        // Page forward twice; ids must never duplicate.
        await store.loadMore()
        await store.loadMore()

        let ids = store.events.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "loadMore appended duplicate events")
        XCTAssertGreaterThanOrEqual(store.events.count, afterFirst)
    }

    /// The guard, exercised against the cursor it exists for.
    ///
    /// A garbage cursor makes the server hand back page one with HTTP 200. With
    /// the dedupe guard removed this appends the whole first page a second time,
    /// so the assertion below is what stands between infinite scroll and an
    /// infinite loop. Driving `loadMore` with a VALID cursor cannot prove this —
    /// verified: removing the guard left that version of the test green.
    @MainActor
    func testLoadMoreIgnoresAPageTheServerRepeated() async throws {
        let store = AppStore(config: ServerConfig(
            baseURL: "http://127.0.0.1:9429", secret: ""
        ))
        await store.refresh()
        let before = store.events.count
        XCTAssertGreaterThan(before, 0)

        await store.loadMore(usingCursor: "NOTBASE64!!")

        XCTAssertEqual(store.events.count, before,
                       "a repeated page was appended — the zero-new-ids guard is gone")
        let ids = store.events.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate events in the feed")
    }

    /// The badge must come from the server, not from counting loaded rows —
    /// the backlog is four figures while a page is 50.
    @MainActor
    func testUnreadCountExceedsLoadedPage() async throws {
        let count = try await client.unreadCount()
        guard count > 50 else {
            throw XCTSkip("backlog is only \(count); this test needs more than one page of unread")
        }

        let store = AppStore(config: ServerConfig(
            baseURL: "http://127.0.0.1:9429", secret: ""
        ))
        await store.refresh()
        XCTAssertGreaterThan(store.unreadCount, store.events.count,
                             "the badge is counting loaded rows instead of asking the server")
    }

    /// Filters compose server-side.
    func testTypeFilterNarrowsResults() async throws {
        let page = try await client.events(limit: 10, type: .progress)
        guard !page.events.isEmpty else { throw XCTSkip("no progress events in the feed") }
        XCTAssertTrue(page.events.allSatisfy { $0.type == .progress })
    }
}
