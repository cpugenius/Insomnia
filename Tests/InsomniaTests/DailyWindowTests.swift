import XCTest
@testable import Insomnia

final class DailyWindowTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        self.calendar = calendar
    }

    /// 15 Jan 2027, standard time. No DST gap.
    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 15) -> Date {
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = 2027
        parts.month = 1
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return calendar.date(from: parts)!
    }

    private func decide(
        at now: Date,
        start: Int = DailyWindow.automaticStart,
        end: Int = DailyWindow.automaticEnd,
        enabled: Bool = true,
        pausedUntil: Date? = nil,
        sessionActive: Bool = false,
        userStopped: Bool = false
    ) -> DailyWindowPolicy.Decision {
        DailyWindowPolicy.decide(DailyWindowPolicy.Context(
            enabled: enabled,
            window: DailyWindow(startMinute: start, endMinute: end),
            pausedUntil: pausedUntil,
            sessionActive: sessionActive,
            userStopped: userStopped,
            now: now,
            calendar: calendar,
            minimumDuration: SessionMath.minimumDuration
        ))
    }

    func testSevenToTwoCoversTheEveningAndTheEarlyMorning() {
        let window = DailyWindow.automatic
        XCTAssertTrue(window.contains(7 * 60))
        XCTAssertTrue(window.contains(23 * 60))
        XCTAssertTrue(window.contains(0))
        XCTAssertTrue(window.contains(1 * 60 + 59))
        XCTAssertFalse(window.contains(2 * 60))
        XCTAssertFalse(window.contains(3 * 60))
        XCTAssertFalse(window.contains(6 * 60 + 59))
    }

    func testTenInTheMorningRunsUntilTwoTheNextDay() {
        let now = at(10, 0)
        let decision = decide(at: now)
        XCTAssertEqual(decision, .init(action: .start(endsAt: at(2, 0, day: 16)), pause: .unchanged))
    }

    func testSevenExactlyRunsUntilTwoTheNextDay() {
        XCTAssertEqual(
            decide(at: at(7, 0)),
            .init(action: .start(endsAt: at(2, 0, day: 16)), pause: .unchanged)
        )
    }

    func testOneThirtyRunsUntilTwoTheSameDay() {
        XCTAssertEqual(
            decide(at: at(1, 30)),
            .init(action: .start(endsAt: at(2, 0)), pause: .unchanged)
        )
    }

    func testTheLastMinuteDoesNotStartASessionShorterThanTheMinimum() {
        let now = at(1, 59, 30)
        XCTAssertEqual(
            decide(at: now),
            .init(action: .check(at: at(7, 0)), pause: .unchanged)
        )
    }

    func testTwoExactlyWaitsForSeven() {
        XCTAssertEqual(
            decide(at: at(2, 0)),
            .init(action: .check(at: at(7, 0)), pause: .unchanged)
        )
    }

    func testThreeInTheMorningWaitsForSeven() {
        XCTAssertEqual(
            decide(at: at(3, 0)),
            .init(action: .check(at: at(7, 0)), pause: .unchanged)
        )
    }

    func testARunningSessionIsLeftAlone() {
        XCTAssertEqual(
            decide(at: at(10, 0), sessionActive: true),
            .init(action: .idle, pause: .unchanged)
        )
    }

    func testEndingEarlyPausesUntilTheNextStart() {
        XCTAssertEqual(
            decide(at: at(10, 0), userStopped: true),
            .init(action: .check(at: at(7, 0, day: 16)), pause: .until(at(7, 0, day: 16)))
        )
        XCTAssertEqual(
            decide(at: at(1, 0), userStopped: true),
            .init(action: .check(at: at(7, 0)), pause: .until(at(7, 0)))
        )
    }

    func testAPauseHoldsUntilItPasses() {
        let pause = at(7, 0, day: 16)
        XCTAssertEqual(
            decide(at: at(22, 0), pausedUntil: pause),
            .init(action: .check(at: pause), pause: .unchanged)
        )
        XCTAssertEqual(
            decide(at: pause, pausedUntil: pause),
            .init(action: .start(endsAt: at(2, 0, day: 17)), pause: .clear)
        )
    }

    func testTurningTheWindowOffClearsThePause() {
        XCTAssertEqual(
            decide(at: at(10, 0), enabled: false, pausedUntil: at(7, 0, day: 16)),
            .init(action: .idle, pause: .clear)
        )
    }

    func testASameDayWindowEndsTheSameAfternoon() {
        XCTAssertEqual(
            decide(at: at(12, 0), start: 9 * 60, end: 17 * 60),
            .init(action: .start(endsAt: at(17, 0)), pause: .unchanged)
        )
        XCTAssertEqual(
            decide(at: at(18, 0), start: 9 * 60, end: 17 * 60),
            .init(action: .check(at: at(9, 0, day: 16)), pause: .unchanged)
        )
    }

    func testEqualStartAndEndNeverRuns() {
        let decision = decide(at: at(10, 0), start: 8 * 60, end: 8 * 60)
        XCTAssertEqual(decision.action, .check(at: at(8, 0, day: 16)))
    }

    func testASessionFileWithoutASourceIsManual() throws {
        let json = #"{"startedAt":"2027-01-15T08:00:00Z","endsAt":"2027-01-15T12:00:00Z","extensions":[]}"#
        let session = try Store.makeDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.source, .manual)
    }

    func testTheMenuNamesTheWindowAndAPause() {
        XCTAssertNil(DailyWindow.statusLine(enabled: false, startMinute: 7 * 60, endMinute: 2 * 60, pausedUntil: nil, now: at(10, 0)))
        let running = DailyWindow.statusLine(enabled: true, startMinute: 7 * 60, endMinute: 2 * 60, pausedUntil: nil, now: at(10, 0))
        XCTAssertTrue(running?.hasPrefix("Awake daily ") == true, running ?? "")
        let paused = at(7, 0, day: 16)
        let line = DailyWindow.statusLine(enabled: true, startMinute: 7 * 60, endMinute: 2 * 60, pausedUntil: paused, now: at(10, 0))
        XCTAssertTrue(line?.hasPrefix("Daily window paused until ") == true, line ?? "")
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: nil,
            dailyWindow: line
        )
        XCTAssertEqual(items.first?.title, line)
        XCTAssertEqual(items.first?.kind, .info)
    }
}

@MainActor
final class DailyWindowSessionTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func local(_ hour: Int, _ minute: Int, _ second: Int = 0, on day: Date? = nil) -> Date {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: day ?? h.clock.now)
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        parts.nanosecond = 0
        return calendar.date(from: parts)!
    }

    private func enableWindow(on manager: SessionManager) throws {
        manager.config.dailyWindowEnabled = true
        manager.config.dailyWindowStartMinute = DailyWindow.automaticStart
        manager.config.dailyWindowEndMinute = DailyWindow.automaticEnd
        manager.config.dailyWindowPausedUntil = nil
        try manager.store.saveConfig(manager.config)
    }

    func testTheWindowStartsUntil2amAndPausesWhenEnded() async throws {
        let m = h.makeManager()
        try enableWindow(on: m)
        let morning = local(10, 0)
        h.clock.now = morning

        await m.syncDailyWindow()

        let session = try XCTUnwrap(m.session)
        XCTAssertEqual(session.source, .dailyWindow)
        let expectedEnd = try XCTUnwrap(DailyWindow.automatic.endsAt(containing: morning, calendar: .current))
        XCTAssertEqual(session.endsAt.timeIntervalSince(expectedEnd), 0, accuracy: 1)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertTrue(h.notifier.posts.contains { $0.title.hasPrefix("Awake until ") })

        _ = await m.end(reason: .user)

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        let paused = try XCTUnwrap(m.config.dailyWindowPausedUntil)
        XCTAssertEqual(paused, DailyWindow.automatic.nextStart(after: morning, calendar: .current))
        XCTAssertEqual(try m.store.loadConfig()?.dailyWindowPausedUntil, paused)
        XCTAssertNil(m.session, "ending early does not start the window again")

        h.clock.now = paused.addingTimeInterval(-60)
        await m.syncDailyWindow()
        XCTAssertNil(m.session)

        h.clock.now = paused
        await m.syncDailyWindow()
        XCTAssertEqual(m.session?.source, .dailyWindow)
        XCTAssertNil(m.config.dailyWindowPausedUntil)
    }

    func testOutsideTheWindowWaitsForTheNextStart() async throws {
        let m = h.makeManager()
        try enableWindow(on: m)
        let night = local(3, 0)
        h.clock.now = night

        await m.syncDailyWindow()

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(m.dailyWindowCheckAt, DailyWindow.automatic.nextStart(after: night, calendar: .current))
    }

    func testQuitDoesNotScheduleTheNextMorning() async throws {
        let m = h.makeManager()
        try enableWindow(on: m)
        h.clock.now = local(10, 0)
        await m.syncDailyWindow()
        XCTAssertNotNil(m.session)

        _ = await m.end(reason: .quit)

        XCTAssertNil(m.session)
        XCTAssertNil(m.dailyWindowCheckAt)
        XCTAssertNil(m.config.dailyWindowPausedUntil)
    }

    func testARelaunchInsideTheWindowResumesItAndAPauseSurvives() async throws {
        let first = h.makeManager()
        try enableWindow(on: first)
        h.clock.now = local(10, 0)
        await first.reconcile()
        XCTAssertEqual(first.session?.source, .dailyWindow)
        _ = await first.end(reason: .user)
        let paused = try XCTUnwrap(first.config.dailyWindowPausedUntil)

        let second = h.makeManager()
        await second.reconcile()
        XCTAssertNil(second.session)
        XCTAssertEqual(second.config.dailyWindowPausedUntil, paused)
        XCTAssertEqual(second.dailyWindowCheckAt, paused)
    }
}
