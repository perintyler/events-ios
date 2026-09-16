import XCTest
@testable import Events

/// Decoding tests pinned to payloads copied from a REAL server response.
///
/// The point is drift: the app and `servers/api` have no shared schema, so a
/// changed field shows up as an app that silently renders nothing rather than
/// as a compile error. Fixtures are taken verbatim from
/// `GET /api/v1/events` on the live API.
final class EventModelTests: XCTestCase {

    /// A `system_alert` from the head of the feed: Slack markup in the title,
    /// an escaped newline, a null session, and an empty deliveredVia.
    private let headPage = """
    {
      "events": [
        {
          "id": "evt_Gs3xZuamvKqqsBq7",
          "type": "system_alert",
          "sessionId": null,
          "source": "cli",
          "title": ":warning: *Barry* MCP transports at 64% of the ceiling\\n_mcp-transport-leak_",
          "body": null,
          "severity": "error",
          "data": { "barry": "bux", "channel": "slack" },
          "metadata": {},
          "deliveredVia": [],
          "readAt": null,
          "createdAt": "2026-09-16T06:18:55.907Z"
        }
      ],
      "nextCursor": "eyJjcmVhdGVkQXQiOiIyMDI2LTA5LTE2In0"
    }
    """

    /// THE decoding test that matters most.
    ///
    /// The route handler writes `{ ok: true, ... }` but the contract middleware
    /// strips `ok` before it reaches the wire — the live top-level keys are
    /// exactly `events` and `nextCursor`. If `EventListResponse` ever grows a
    /// non-optional `ok`, EVERY successful response fails to decode. This test
    /// pins that, and its negative control is to add `let ok: Bool` and watch
    /// this go red.
    func testDecodesListResponseWithNoOkField() throws {
        let response = try JSONDecoder.barry.decode(
            EventListResponse.self, from: Data(headPage.utf8)
        )
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.nextCursor, "eyJjcmVhdGVkQXQiOiIyMDI2LTA5LTE2In0")
        XCTAssertEqual(response.events[0].id, "evt_Gs3xZuamvKqqsBq7")
    }

    func testDecodesNullSessionAndEmptyDelivery() throws {
        let event = try firstEvent(from: headPage)
        XCTAssertNil(event.sessionId)
        XCTAssertTrue(event.deliveredVia.isEmpty)
        XCTAssertNil(event.body)
        XCTAssertTrue(event.isUnread)
        XCTAssertEqual(event.severity, .error)
        XCTAssertEqual(event.type, .systemAlert)
    }

    /// Slack markup must not leak into the feed.
    func testDisplayTitleRendersSlackMarkup() throws {
        let event = try firstEvent(from: headPage)
        let title = event.displayTitle

        XCTAssertTrue(title.hasPrefix("⚠️"), "shortcode should become an emoji: \(title)")
        XCTAssertFalse(title.contains(":warning:"))
        XCTAssertFalse(title.contains("*"), "bold markers should be stripped")
        XCTAssertFalse(title.contains("\\n"), "escaped newline should become a real one")
        XCTAssertTrue(title.contains("\n"))
    }

    /// The feed row shows one line; a progress title can run to hundreds of
    /// characters across several lines.
    func testSummaryLineIsFirstLineOnly() throws {
        let event = try firstEvent(from: headPage)
        XCTAssertFalse(event.summaryLine.contains("\n"))
        XCTAssertTrue(event.summaryLine.contains("MCP transports"))
        XCTAssertFalse(event.summaryLine.contains("mcp-transport-leak"))
    }

    /// Timestamps arrive WITH fractional seconds in practice; the parser must
    /// also accept the form without them.
    func testParsesBothTimestampForms() throws {
        let withFraction = try firstEvent(from: headPage)
        XCTAssertEqual(withFraction.createdAt.timeIntervalSince1970, 1_789_539_535.907, accuracy: 0.01)

        let plain = headPage.replacingOccurrences(
            of: "2026-09-16T06:18:55.907Z", with: "2026-09-16T06:18:55Z"
        )
        let event = try firstEvent(from: plain)
        XCTAssertEqual(event.createdAt.timeIntervalSince1970, 1_789_539_535, accuracy: 0.01)
    }

    /// An unknown type must render as an ordinary event, not fail the page.
    func testUnknownTypeFallsBackRatherThanThrowing() throws {
        let payload = headPage.replacingOccurrences(
            of: "\"type\": \"system_alert\"", with: "\"type\": \"brand_new_kind\""
        )
        let event = try firstEvent(from: payload)
        XCTAssertEqual(event.type, .other("brand_new_kind"))
        XCTAssertEqual(event.type.label, "BRAND_NEW_KIND")
    }

    /// Same for severity — the column is plain TEXT server-side.
    func testUnknownSeverityFallsBackToInfo() throws {
        let payload = headPage.replacingOccurrences(
            of: "\"severity\": \"error\"", with: "\"severity\": \"catastrophic\""
        )
        XCTAssertEqual(try firstEvent(from: payload).severity, .info)
    }

    /// A progress event carries the phase and a real session id.
    func testProgressEventExposesPhaseAndSession() throws {
        let payload = """
        {
          "events": [{
            "id": "evt_cI112tjpRZGQOyRY",
            "type": "progress",
            "sessionId": "Xuy6sGAWEyfw6qZ_ZAcQb",
            "source": "mcp",
            "title": "Flag audit COMPLETE",
            "body": null,
            "severity": "success",
            "data": { "phase": "complete", "barry": "bux" },
            "metadata": {},
            "deliveredVia": ["slack"],
            "readAt": "2026-09-16T07:00:00.000Z",
            "createdAt": "2026-09-16T06:00:00.000Z"
          }],
          "nextCursor": null
        }
        """
        let event = try firstEvent(from: payload)
        XCTAssertEqual(event.phase, "complete")
        XCTAssertEqual(event.sessionId, "Xuy6sGAWEyfw6qZ_ZAcQb")
        XCTAssertFalse(event.isUnread)
        XCTAssertEqual(event.deliveredVia, ["slack"])
        // `phase` is shown on its own line, so it is excluded from the pairs.
        XCTAssertEqual(event.detailPairs.map(\.key), ["barry"])
    }

    /// `data` carries arbitrary nested JSON — a task_finished error payload has
    /// a deeply escaped string in it. It must survive decoding and render.
    func testNestedDataDecodesAndRenders() throws {
        let payload = """
        {
          "events": [{
            "id": "evt_x", "type": "task_finished", "sessionId": "s1",
            "source": "system", "title": "Session failed", "body": null,
            "severity": "error",
            "data": { "status": "failed", "counts": { "retries": 3 }, "ok": false },
            "metadata": { "host": "bux" }, "deliveredVia": [],
            "readAt": null, "createdAt": "2026-09-15T08:18:18.168Z"
          }],
          "nextCursor": null
        }
        """
        let event = try firstEvent(from: payload)
        let pairs = Dictionary(uniqueKeysWithValues: event.detailPairs.map { ($0.key, $0.value) })
        XCTAssertEqual(pairs["status"], "failed")
        XCTAssertEqual(pairs["counts"], "retries: 3")
        XCTAssertEqual(pairs["ok"], "false")
        XCTAssertEqual(event.metadataPairs.first?.value, "bux")
    }

    /// Optimistic mark-read must not drop fields added to the model later.
    func testMarkingReadPreservesEveryField() throws {
        let event = try firstEvent(from: headPage)
        let read = event.markingRead(at: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNotNil(read.readAt)
        XCTAssertFalse(read.isUnread)
        XCTAssertEqual(read.id, event.id)
        XCTAssertEqual(read.title, event.title)
        XCTAssertEqual(read.data, event.data)
        XCTAssertEqual(read.metadata, event.metadata)
        XCTAssertEqual(read.deliveredVia, event.deliveredVia)
        XCTAssertEqual(read.createdAt, event.createdAt)
        XCTAssertEqual(read.severity, event.severity)
        XCTAssertEqual(read.sessionId, event.sessionId)
    }

    func testUnreadCountDecodesBarePayload() throws {
        let decoded = try JSONDecoder.barry.decode(
            UnreadCountResponse.self, from: Data(#"{"count":1304}"#.utf8)
        )
        XCTAssertEqual(decoded.count, 1304)
    }

    // MARK: - Helper

    private func firstEvent(from json: String) throws -> BarryEvent {
        let response = try JSONDecoder.barry.decode(EventListResponse.self, from: Data(json.utf8))
        return try XCTUnwrap(response.events.first)
    }
}
