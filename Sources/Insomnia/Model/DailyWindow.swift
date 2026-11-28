import Foundation

/// Local-time hours during which Insomnia keeps a session running.
///
/// Minutes are from local midnight, in `0..<1440`. The window is half-open:
/// it includes the start minute and excludes the end minute. An end at or
/// before the start crosses midnight, so 7:00 to 2:00 covers 7:00 AM through
/// 1:59 AM and lets the Mac sleep from 2:00 AM to 7:00 AM.
struct DailyWindow: Equatable, Sendable {
    var startMinute: Int
    var endMinute: Int

    static let minutesPerDay = 24 * 60
    /// 7:00 AM.
    static let automaticStart = 7 * 60
    /// 2:00 AM, the next day.
    static let automaticEnd = 2 * 60
    static let automatic = DailyWindow(startMinute: automaticStart, endMinute: automaticEnd)

    var normalized: DailyWindow {
        DailyWindow(startMinute: Self.clamp(startMinute), endMinute: Self.clamp(endMinute))
    }

    /// Fold any integer into `0..<minutesPerDay`.
    static func clamp(_ minute: Int) -> Int {
        let wrapped = minute % minutesPerDay
        return wrapped >= 0 ? wrapped : wrapped + minutesPerDay
    }

    /// The minute of the local day, seconds dropped.
    static func minute(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clamp((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// A date on `day`'s local calendar day at `minute:00`. Nil when that
    /// clock time does not exist (a spring-forward gap).
    static func boundary(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        let minute = clamp(minute)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = minute / 60
        parts.minute = minute % 60
        parts.second = 0
        parts.nanosecond = 0
        guard let date = calendar.date(from: parts) else { return nil }
        // A gap can come back as a later hour. Only an exact match counts.
        guard self.minute(of: date, calendar: calendar) == minute else { return nil }
        return date
    }

    /// Soonest `minute:00` strictly after `now`.
    static func nextOccurrence(of minute: Int, after now: Date, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: now)
        for _ in 0..<4 {
            if let boundary = boundary(minute, on: day, calendar: calendar), boundary > now {
                return boundary
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return now.addingTimeInterval(TimeInterval(minutesPerDay * 60))
    }

    func contains(_ minuteOfDay: Int) -> Bool {
        let start = Self.clamp(startMinute)
        let end = Self.clamp(endMinute)
        let minute = Self.clamp(minuteOfDay)
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    /// When the occurrence that contains `now` ends. Nil outside the window.
    func endsAt(containing now: Date, calendar: Calendar) -> Date? {
        let window = normalized
        guard window.contains(Self.minute(of: now, calendar: calendar)) else { return nil }
        return Self.nextOccurrence(of: window.endMinute, after: now, calendar: calendar)
    }

    /// The next time the window opens, strictly after `now`.
    func nextStart(after now: Date, calendar: Calendar) -> Date {
        Self.nextOccurrence(of: normalized.startMinute, after: now, calendar: calendar)
    }

    /// "7:00 AM" in the current locale.
    static func clockLabel(_ minute: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let shown = boundary(minute, on: now, calendar: calendar)
            ?? nextOccurrence(of: minute, after: now.addingTimeInterval(-1), calendar: calendar)
        return shown.formatted(date: .omitted, time: .shortened)
    }

    /// The right-click menu line. Nil when the window is off.
    static func statusLine(
        enabled: Bool,
        startMinute: Int,
        endMinute: Int,
        pausedUntil: Date?,
        now: Date
    ) -> String? {
        guard enabled else { return nil }
        if let pausedUntil, pausedUntil > now {
            return "Daily window paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))"
        }
        return "Awake daily \(clockLabel(startMinute))–\(clockLabel(endMinute))"
    }

    /// The note under the hours in Settings.
    static func settingsNote(startMinute: Int, endMinute: Int) -> String {
        let start = clockLabel(startMinute)
        let end = clockLabel(endMinute)
        let window = DailyWindow(startMinute: startMinute, endMinute: endMinute).normalized
        if window.startMinute == window.endMinute {
            return "The start and end are the same, so this never starts a session."
        }
        let span = window.startMinute > window.endMinute
            ? "Awake from \(start) to \(end) every day, including overnight. The Mac can sleep from \(end) to \(start)."
            : "Awake from \(start) to \(end) every day. The Mac can sleep the rest of the time."
        return span + " Ending a session early pauses this until \(start). A session already running keeps its end time. Insomnia has to be open at \(start), including after a restart, so turn on Launch at login."
    }
}

/// What the daily window should do at one instant. No clocks, no disk.
enum DailyWindowPolicy {
    struct Context {
        var enabled: Bool
        var window: DailyWindow
        var pausedUntil: Date?
        var sessionActive: Bool
        /// The user, or a battery or heat floor, just ended the session.
        /// The window stays out until its next start.
        var userStopped: Bool
        var now: Date
        var calendar: Calendar
        var minimumDuration: TimeInterval
    }

    struct Decision: Equatable {
        enum Action: Equatable {
            case idle
            case check(at: Date)
            case start(endsAt: Date)
        }

        enum Pause: Equatable {
            case unchanged
            case clear
            case until(Date)
        }

        var action: Action
        var pause: Pause
    }

    static func decide(_ context: Context) -> Decision {
        let window = context.window.normalized
        guard context.enabled else {
            return Decision(action: .idle, pause: .clear)
        }
        if context.userStopped {
            let next = window.nextStart(after: context.now, calendar: context.calendar)
            return Decision(action: .check(at: next), pause: .until(next))
        }
        if let paused = context.pausedUntil, paused > context.now {
            return Decision(action: .check(at: paused), pause: .unchanged)
        }
        let pause: Decision.Pause = context.pausedUntil == nil ? .unchanged : .clear
        if context.sessionActive {
            return Decision(action: .idle, pause: pause)
        }
        if let endsAt = window.endsAt(containing: context.now, calendar: context.calendar),
           endsAt.timeIntervalSince(context.now) >= context.minimumDuration {
            return Decision(action: .start(endsAt: endsAt), pause: pause)
        }
        return Decision(action: .check(at: window.nextStart(after: context.now, calendar: context.calendar)), pause: pause)
    }
}
