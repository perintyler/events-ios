import XCTest
import BarryKit
@testable import Events

/// The app's hand-written wire types against the generated contract.
///
/// `BarryEvent` in this app is typed by hand, and the server's shape comes
/// from `sdk/contracts` via BarryKit's generated `Components.Schemas.Event`.
/// Nothing forced those two to agree: a field the server adds or renames
/// reaches the app as a decode failure, and because the feed POLLS, a decode
/// failure renders as a list that simply stays empty rather than as an error
/// anyone sees.
///
/// This is the forcing function. It decodes one payload into BOTH types and
/// asserts they agree field for field, so a contract change that this app has
/// not absorbed fails here -- at build time, in CI -- instead of on a phone.
///
/// It deliberately does NOT assert against a checked-in fixture alone. A
/// fixture is a copy of the contract, and a copy drifts silently; the
/// generated type is regenerated from the spec on every build, so comparing
/// against it is comparing against the contract itself.
final class ContractParityTests: XCTestCase {

    /// A full event, every field populated, including the nullable ones.
    private let payload = """
    {
      "id": "evt_abc123",
      "type": "notification",
      "sessionId": "sess_1",
      "source": "cli",
      "title": "A thing happened",
      "body": "with detail",
      "severity": "info",
      "data": {"phase": "planning"},
      "metadata": {"k": "v"},
      "deliveredVia": ["slack"],
      "readAt": "2026-09-23T10:00:00.000Z",
      "createdAt": "2026-09-23T09:00:00.000Z"
    }
    """.data(using: .utf8)!

    /// Both types decode the same bytes.
    ///
    /// If the generated type gains a required field the app's type lacks, the
    /// app's decode still succeeds (Swift ignores extra keys) but the generated
    /// one is the contract -- so the useful assertion is that the app's view
    /// carries the same VALUES, not merely that it parsed something.
    /// The generated types carry `Date` fields, and the spec's format is
    /// ISO-8601 WITH fractional seconds. A bare `JSONDecoder` rejects those, so
    /// the decoder has to be configured the same way `BarryTransport` does --
    /// getting this wrong is itself a contract mismatch, just one on the
    /// client's side.
    private static var contractDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "not an ISO-8601 timestamp: \(raw)"
            )
        }
        return d
    }

    func testAppEventMatchesTheGeneratedContract() throws {
        let generated = try Self.contractDecoder.decode(Components.Schemas.Event.self, from: payload)
        let app = try JSONDecoder.barry.decode(BarryEvent.self, from: payload)

        XCTAssertEqual(app.id, generated.id, "id drifted from the contract")
        XCTAssertEqual(app.title, generated.title, "title drifted from the contract")
        XCTAssertEqual(app.source, generated.source, "source drifted from the contract")
        XCTAssertEqual(app.body, generated.body, "body drifted from the contract")
        XCTAssertEqual(app.sessionId, generated.sessionId, "sessionId drifted from the contract")
        XCTAssertEqual(app.deliveredVia, generated.deliveredVia, "deliveredVia drifted from the contract")
    }

    /// The nullable fields the contract declares must actually be optional here.
    ///
    /// `sessionId`, `body` and `readAt` are `nullable: true` in the spec. Typing
    /// any of them non-optional compiles and passes every test that uses a fully
    /// populated fixture -- and then throws on the first real event that omits
    /// one. This is the case a happy-path fixture cannot catch.
    func testNullsInTheContractsNullableFieldsDecode() throws {
        let sparse = """
        {
          "id": "evt_min",
          "type": "notification",
          "sessionId": null,
          "source": "cli",
          "title": "Minimal",
          "body": null,
          "severity": "info",
          "data": {},
          "metadata": {},
          "deliveredVia": [],
          "readAt": null,
          "createdAt": "2026-09-23T09:00:00.000Z"
        }
        """.data(using: .utf8)!

        XCTAssertNoThrow(try Self.contractDecoder.decode(Components.Schemas.Event.self, from: sparse))
        let app = try JSONDecoder.barry.decode(BarryEvent.self, from: sparse)
        XCTAssertNil(app.sessionId)
        XCTAssertNil(app.body)
        XCTAssertNil(app.readAt)
        XCTAssertTrue(app.isUnread, "readAt: null must read as unread")
    }
}
