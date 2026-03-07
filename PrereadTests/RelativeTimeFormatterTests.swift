import Testing
import Foundation
@testable import Preread

struct RelativeTimeFormatterTests {
    // Fixed reference point: 2025-03-15 14:30:00 UTC
    private let calendar = Calendar.current
    private let now: Date = {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 15
        components.hour = 14
        components.minute = 30
        components.second = 0
        return Calendar.current.date(from: components)!
    }()

    // MARK: - Just now (< 60 seconds)

    @Test func justNow_zeroSeconds() {
        let result = RelativeTimeFormatter.string(from: now, relativeTo: now)
        #expect(result == "Just now")
    }

    @Test func justNow_30seconds() {
        let date = now.addingTimeInterval(-30)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "Just now")
    }

    @Test func justNow_59seconds() {
        let date = now.addingTimeInterval(-59)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "Just now")
    }

    // MARK: - Minutes (1–59m)

    @Test func minutes_exactly1() {
        let date = now.addingTimeInterval(-60)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "1m ago")
    }

    @Test func minutes_30() {
        let date = now.addingTimeInterval(-30 * 60)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "30m ago")
    }

    @Test func minutes_59() {
        let date = now.addingTimeInterval(-59 * 60)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "59m ago")
    }

    // MARK: - Hours (1–23h, same calendar day)

    @Test func hours_exactly1() {
        let date = now.addingTimeInterval(-3600)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "1h ago")
    }

    @Test func hours_5() {
        let date = now.addingTimeInterval(-5 * 3600)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "5h ago")
    }

    // MARK: - Yesterday (calendar-based, not just 24h)

    @Test func yesterday_calendarBased() {
        // Yesterday at 23:59 — only ~14.5 hours ago but different calendar day
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 14
        components.hour = 23
        components.minute = 59
        let date = calendar.date(from: components)!
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "Yesterday")
    }

    @Test func yesterday_earlyMorning() {
        // Yesterday at 01:00
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 14
        components.hour = 1
        components.minute = 0
        let date = calendar.date(from: components)!
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "Yesterday")
    }

    @Test func yesterday_notJust24Hours() {
        // 23 hours ago but still same calendar day (should be hours, not yesterday)
        // now is 14:30, so 23h ago is yesterday 15:30 — that IS yesterday
        // Use a now of 23:30 so 23h ago is 00:30 same day
        var nowComponents = DateComponents()
        nowComponents.year = 2025
        nowComponents.month = 3
        nowComponents.day = 15
        nowComponents.hour = 23
        nowComponents.minute = 30
        let lateNow = calendar.date(from: nowComponents)!

        let date = lateNow.addingTimeInterval(-23 * 3600) // 00:30 same day
        let result = RelativeTimeFormatter.string(from: date, relativeTo: lateNow)
        #expect(result == "23h ago")
    }

    // MARK: - Days (2–6)

    @Test func days_2() {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 13
        components.hour = 10
        let date = calendar.date(from: components)!
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "2 days ago")
    }

    @Test func days_6() {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 9
        components.hour = 10
        let date = calendar.date(from: components)!
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)
        #expect(result == "6 days ago")
    }

    // MARK: - 7+ days (medium date)

    @Test func sevenDays_noPrefix() {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 10
        let date = calendar.date(from: components)!
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)

        // Should be a medium-formatted date string without prefix
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let expected = formatter.string(from: date)
        #expect(result == expected)
    }

    @Test func sevenDays_withPrefix() {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 1
        components.hour = 10
        let date = calendar.date(from: components)!
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now, prefix: "Last fetched")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let expected = "Last fetched \(formatter.string(from: date))"
        #expect(result == expected)
    }

    // MARK: - Edge: future date

    @Test func futureDate_showsMediumDate() {
        let date = now.addingTimeInterval(3600)
        let result = RelativeTimeFormatter.string(from: date, relativeTo: now)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let expected = formatter.string(from: date)
        #expect(result == expected)
    }
}
