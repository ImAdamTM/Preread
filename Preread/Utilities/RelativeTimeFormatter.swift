import Foundation

enum RelativeTimeFormatter {
    /// Returns a human-readable relative time string.
    ///
    /// - Parameters:
    ///   - date: The date to format.
    ///   - now: The reference date (defaults to current time).
    ///   - prefix: Optional prefix for dates older than 6 days (e.g. "Last fetched").
    static func string(from date: Date, relativeTo now: Date = Date(), prefix: String? = nil) -> String {
        let calendar = Calendar.current
        let seconds = now.timeIntervalSince(date)

        guard seconds >= 0 else { return formattedMediumDate(date, prefix: prefix) }

        if seconds < 60 {
            return "Just now"
        }

        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = Int(seconds / 3600)
        if hours < 24 {
            // Check if it's still "today" vs "yesterday" in calendar terms
            if calendar.isDate(date, inSameDayAs: now) {
                return "\(hours)h ago"
            }
            // Falls through to yesterday check below
        }

        if isCalendarYesterday(date, relativeTo: now, calendar: calendar) {
            return "Yesterday"
        }

        // For dates within the last week but more than a day ago
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDateDay = calendar.startOfDay(for: date)
        if let daysBetween = calendar.dateComponents([.day], from: startOfDateDay, to: startOfToday).day,
           daysBetween >= 2 && daysBetween <= 6 {
            return "\(daysBetween) days ago"
        }

        // For "Xh ago" when within the same calendar day but hours > 0
        if hours >= 1 && hours < 24 && calendar.isDate(date, inSameDayAs: now) {
            return "\(hours)h ago"
        }

        return formattedMediumDate(date, prefix: prefix)
    }

    private static func isCalendarYesterday(_ date: Date, relativeTo now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }

    private static func formattedMediumDate(_ date: Date, prefix: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dateString = formatter.string(from: date)
        if let prefix {
            return "\(prefix) \(dateString)"
        }
        return dateString
    }
}
