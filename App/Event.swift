import Foundation

/// One row of the Barry event feed.
///
/// Ported from `bags/sessions/sessions-macos/app/Features/Events/Event.swift`,
/// which had already been hardened against this API's quirks. Changes for iOS:
/// the `Components` import is dropped (a macOS-only SwiftPM target), and
/// `metadata` / `deliveredVia` are added because the detail view shows them.
///
/// `type` and `severity` decode leniently: the API does no output validation on
/// the read path, so an unrecognised value must render as an ordinary event
/// rather than failing the whole page. `source` is free-form text server-side
/// (`"mcp"`, `"api"`, `"cli"`, `"system"`, …) and is deliberately a plain String.
struct BarryEvent: Decodable, Identifiable, Equatable {
    let id: String
    let type: EventType
    let sessionId: String?
    let source: String
    let title: String
    let body: String?
    let severity: Severity
    let data: [String: JSONValue]
    let metadata: [String: JSONValue]
    let deliveredVia: [String]
    let readAt: Date?
    let createdAt: Date

    init(
        id: String, type: EventType, sessionId: String?, source: String,
        title: String, body: String?, severity: Severity,
        data: [String: JSONValue], metadata: [String: JSONValue],
        deliveredVia: [String], readAt: Date?, createdAt: Date
    ) {
        self.id = id
        self.type = type
        self.sessionId = sessionId
        self.source = source
        self.title = title
        self.body = body
        self.severity = severity
        self.data = data
        self.metadata = metadata
        self.deliveredVia = deliveredVia
        self.readAt = readAt
        self.createdAt = createdAt
    }

    var isUnread: Bool { readAt == nil }

    /// Progress events carry the phase the agent was in.
    var phase: String? {
        if case .string(let s) = data["phase"] { return s }
        return nil
    }

    /// Bags named by a `bag_auth` event — the ones a click should authorize.
    var authBags: [String] {
        guard case .array(let items) = data["bags"] else { return [] }
        return items.compactMap { item in
            if case .string(let name) = item { return name }
            return nil
        }
    }

    /// Titles are written for whatever channel produced them — `barry notify`
    /// composes Slack markup, so shortcodes and escaped newlines arrive verbatim.
    /// Render them as plain text rather than leaking `:white_check_mark:` and
    /// literal `\n` into the feed.
    ///
    /// `_underscores_` are deliberately NOT stripped. Slack italics wrap a
    /// trailing detail line (`_swap-exhausted · after 22m_`) and removing the
    /// markers would also eat the underscores inside identifiers like
    /// `mcp-transport-leak`, which read worse than the markers do.
    var displayTitle: String {
        title
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: ":white_check_mark:", with: "✅")
            .replacingOccurrences(of: ":x:", with: "❌")
            .replacingOccurrences(of: ":warning:", with: "⚠️")
            .replacingOccurrences(of: ":rotating_light:", with: "🚨")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first line only — feed rows show this, detail shows the whole thing.
    /// Progress titles run to several hundred characters with newlines in them.
    var summaryLine: String {
        displayTitle.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? displayTitle
    }

    /// A key identifying "the same alert again".
    ///
    /// The feed is dominated by repeats: a 100-event sample held 22 distinct
    /// titles, one of them 40 times. Grouping needs the varying part — the
    /// percentage, the megabytes — removed, so `MCP transports at 64%` and
    /// `... at 71%` collapse together. Digits go to `#`; the emoji prefix stays
    /// because a "Recovered" ✅ is genuinely a different event from the ⚠️ that
    /// preceded it.
    var recurrenceKey: String {
        let line = summaryLine
        var out = ""
        var lastWasDigit = false
        for ch in line {
            if ch.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                out.append(ch)
                lastWasDigit = false
            }
        }
        return "\(type.wireValue)|\(severity.rawValue)|\(out)"
    }

    /// `data` minus the keys already shown in the row's own metadata line.
    var detailPairs: [(key: String, value: String)] {
        data
            .filter { $0.key != "phase" && $0.key != "summary" }
            .map { (key: $0.key, value: $0.value.displayString) }
            .sorted { $0.key < $1.key }
    }

    var metadataPairs: [(key: String, value: String)] {
        metadata
            .map { (key: $0.key, value: $0.value.displayString) }
            .sorted { $0.key < $1.key }
    }

    /// A copy marked read, for optimistic UI updates.
    ///
    /// Every field is carried through explicitly. An earlier shape that rebuilt
    /// only the fields it knew about silently blanked the ones added later.
    func markingRead(at date: Date = Date()) -> BarryEvent {
        BarryEvent(
            id: id, type: type, sessionId: sessionId, source: source,
            title: title, body: body, severity: severity,
            data: data, metadata: metadata, deliveredVia: deliveredVia,
            readAt: readAt ?? date, createdAt: createdAt
        )
    }
}

enum EventType: Decodable, Equatable, Hashable {
    case progress
    case notification
    case taskFinished
    case systemAlert
    case other(String)

    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "progress": self = .progress
        case "notification": self = .notification
        case "task_finished": self = .taskFinished
        case "system_alert": self = .systemAlert
        case let raw: self = .other(raw)
        }
    }

    /// Short uppercase tag shown in the row's metadata line.
    var label: String {
        switch self {
        case .progress: return "PROGRESS"
        case .notification: return "NOTIFY"
        case .taskFinished: return "DONE"
        case .systemAlert: return "ALERT"
        case .other(let raw): return raw.uppercased()
        }
    }

    /// The value the API expects in a `?type=` filter.
    var wireValue: String {
        switch self {
        case .progress: return "progress"
        case .notification: return "notification"
        case .taskFinished: return "task_finished"
        case .systemAlert: return "system_alert"
        case .other(let raw): return raw
        }
    }

    /// The four the server's closed enum actually accepts as filters.
    static let filterable: [EventType] = [.progress, .notification, .taskFinished, .systemAlert]
}

enum Severity: String, Decodable, Equatable, CaseIterable {
    case info, warn, error, success

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Severity(rawValue: raw) ?? .info
    }
}

/// Minimal JSON value so `data` (arbitrary server-side payload) survives decoding.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int(n))
                : String(n)
        case .array(let a):
            return a.map(\.displayString).joined(separator: ", ")
        case .object(let o):
            return o.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayString)" }
                .joined(separator: ", ")
        }
    }
}

/// The list envelope.
///
/// There is deliberately NO `ok` field. `servers/api/src/routes/events.ts`
/// writes `res.json({ ok: true, ... })`, but the API's contract middleware
/// strips it before the response goes out — verified against the live server,
/// whose top-level keys are exactly `events` and `nextCursor`. A non-optional
/// `ok` here would fail decoding on every single successful response.
struct EventListResponse: Decodable {
    let events: [BarryEvent]
    let nextCursor: String?
}

/// `GET /api/v1/events/unread-count` — likewise just `{ "count": N }`.
struct UnreadCountResponse: Decodable {
    let count: Int
}

/// `POST /api/v1/events/read-all` — `{ "count": N }`.
struct MarkAllReadResponse: Decodable {
    let count: Int
}

/// Barry timestamps are ISO8601 and *may* carry fractional seconds
/// (`2026-07-24T02:40:42.332Z`). `.iso8601` alone rejects those, so try both.
///
/// The formatters are built per call rather than shared: `ISO8601DateFormatter`
/// is not `Sendable`, and capturing one in the decoding closure is an error
/// under the Swift 6 language mode.
private func parseBarryDate(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}

extension JSONDecoder {
    static var barry: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseBarryDate(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }
}

/// One row of the rendered feed — an event, plus how many consecutive repeats
/// of it were folded in. `repeatCount == 1` is the ungrouped case.
struct FeedRow: Identifiable, Equatable {
    var event: BarryEvent
    var repeatCount: Int

    var id: String { event.id }
}
