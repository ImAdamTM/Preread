import Foundation

/// Estimates and formats reading time based on word count.
/// Uses ~200 words per minute average reading speed.
enum ReadingTimeFormatter {

    // MARK: - Estimation

    /// Estimates reading minutes from a word count (200 wpm, rounded up, min 1).
    static func estimateMinutes(wordCount: Int) -> Int {
        max(1, (wordCount + 199) / 200)
    }

    // MARK: - Per-article formatting

    /// Short form for per-article display: "1 min read", "5 min read", etc.
    static func articleFormatted(minutes: Int) -> String {
        "\(minutes) min read"
    }

    // MARK: - Aggregate formatting

    /// Human-readable condensed reading time for aggregate display.
    ///
    /// Rules:
    /// - 0 min        → nil (caller should hide)
    /// - 1-4 min      → "5min"
    /// - 5-9 min      → exact: "5min", "8min"
    /// - 10-59 min    → rounded to nearest 5: "10min", "30min", "55min"
    /// - 60-299 min   → hours + remaining 5-min blocks: "1hr", "1hr 30min", "2hr 45min"
    /// - ≥300 min     → "5hr+"
    static func formatted(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }

        if minutes < 5 {
            return "5min"
        }

        if minutes >= 300 {
            return "5hr+"
        }

        let rounded = minutes < 10 ? minutes : roundToNearest5(minutes)

        if rounded < 60 {
            return "\(rounded)min"
        }

        let hours = rounded / 60
        let remainingMinutes = rounded % 60
        if remainingMinutes == 0 {
            return "\(hours)hr"
        }
        return "\(hours)hr \(remainingMinutes)min"
    }

    // MARK: - Helpers

    private static func roundToNearest5(_ value: Int) -> Int {
        ((value + 2) / 5) * 5
    }
}
