import Foundation

/// Who asked for the session. A file written before this field existed
/// decodes as `.manual`.
enum SessionSource: String, Codable, Equatable, Sendable {
    case manual
    case dailyWindow
}

/// An active keep-awake session. `endsAt` is the only thing that keeps sleep
/// disabled; everything else is bookkeeping.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date
    /// Every extension applied, in order, in seconds.
    var extensions: [TimeInterval]
    var source: SessionSource

    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = [], source: SessionSource = .manual) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        extensions = try c.decodeIfPresent([TimeInterval].self, forKey: .extensions) ?? []
        source = try c.decodeIfPresent(SessionSource.self, forKey: .source) ?? .manual
    }

    /// Seconds left until `endsAt`, never negative.
    func remaining(at now: Date) -> TimeInterval {
        SessionMath.remaining(until: endsAt, at: now)
    }

    /// True once `now` reaches `endsAt`.
    func isExpired(at now: Date) -> Bool {
        SessionMath.isExpired(endsAt: endsAt, at: now)
    }

    /// Shape of the menu bar countdown, derived from the session's span so it
    /// survives a relaunch without another persisted field. Because
    /// `remaining` never exceeds this span, the shape always has room for the
    /// value. An extension widens the span and can promote the shape, which
    /// is a one-off change at a user action, never a per-tick one.
    var countdownShape: CountdownShape {
        CountdownShape(initialDuration: endsAt.timeIntervalSince(startedAt))
    }
}
