import SwiftUI

/// Colours and formatting shared by the views.
///
/// Written against SwiftUI's built-in colours rather than ported from the
/// macOS app's `Palette`, which lives in the `Components` SwiftPM target and is
/// not available here. Semantic colours also adapt to dark mode for free.
enum Theme {
    static func tint(for severity: Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    static func tint(for type: EventType) -> Color {
        switch type {
        case .progress: return .blue
        case .notification: return .purple
        case .taskFinished: return .green
        case .systemAlert: return .orange
        case .other: return .secondary
        }
    }

    /// "4m", "2h", "3d" — compact enough for a metadata line.
    static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}
