import XCTest
@testable import MacAIMagic

final class TaskScheduleTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    private func text(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm EEE"
        return f.string(from: d)
    }

    func testOnce() {
        let at = date("2026-11-08 10:00")
        XCTAssertEqual(TaskSchedule.once(at).next(after: date("2026-11-07 12:00"), calendar: cal), at)
        XCTAssertNil(TaskSchedule.once(at).next(after: at, calendar: cal), "a single run that is past")
    }

    func testDailyAndWorkdays() {
        // Saturday 7 November 2026, 12:00
        let sat = date("2026-11-07 12:00")
        XCTAssertEqual(text(TaskSchedule.daily(hour: 8, minute: 0, weekdaysOnly: false).next(after: sat, calendar: cal)), "2026-11-08 08:00 Sun")
        XCTAssertEqual(text(TaskSchedule.daily(hour: 8, minute: 0, weekdaysOnly: true).next(after: sat, calendar: cal)), "2026-11-09 08:00 Mon")
        XCTAssertEqual(text(TaskSchedule.daily(hour: 13, minute: 30, weekdaysOnly: false).next(after: sat, calendar: cal)), "2026-11-07 13:30 Sat", "later today")
    }

    func testWeekly() {
        // 6 = Friday
        XCTAssertEqual(text(TaskSchedule.weekly(weekday: 6, hour: 17, minute: 0).next(after: date("2026-11-07 12:00"), calendar: cal)), "2026-11-13 17:00 Fri")
    }

    func testEveryFewHoursWithinActiveHours() {
        let s = TaskSchedule.every(hours: 2, from: 8, to: 22)
        XCTAssertEqual(text(s.next(after: date("2026-11-07 12:00"), calendar: cal)), "2026-11-07 14:00 Sat")
        XCTAssertEqual(text(s.next(after: date("2026-11-07 21:00"), calendar: cal)), "2026-11-08 08:00 Sun", "after the active hours: the next morning")
        XCTAssertEqual(text(s.next(after: date("2026-11-07 05:00"), calendar: cal)), "2026-11-07 08:00 Sat")
        XCTAssertEqual(text(TaskSchedule.every(hours: 1, from: 0, to: 0).next(after: date("2026-11-07 23:10"), calendar: cal)), "2026-11-08 00:00 Sun", "the whole day")
        XCTAssertEqual(text(TaskSchedule.every(hours: 1, from: 22, to: 2).next(after: date("2026-11-07 23:10"), calendar: cal)), "2026-11-08 00:00 Sun", "a window past midnight")
    }

    /// Summer time starts on 29 March 2026 (02:00 → 03:00) and ends on 25 October 2026 (03:00 → 02:00).
    func testSummerAndWinterTime() {
        let spring = TaskSchedule.daily(hour: 2, minute: 30, weekdaysOnly: false).next(after: date("2026-03-28 12:00"), calendar: cal)
        XCTAssertEqual(text(spring).map { String($0.prefix(10)) }, "2026-03-29", "02:30 does not exist that night: it runs that night all the same")
        XCTAssertEqual(text(TaskSchedule.daily(hour: 8, minute: 0, weekdaysOnly: false).next(after: date("2026-10-24 12:00"), calendar: cal)), "2026-10-25 08:00 Sun")
        // the night the clock goes back is an hour longer: 25 hours between the two morning runs
        let a = TaskSchedule.daily(hour: 8, minute: 0, weekdaysOnly: false).next(after: date("2026-10-24 07:00"), calendar: cal)!
        let b = TaskSchedule.daily(hour: 8, minute: 0, weekdaysOnly: false).next(after: a, calendar: cal)!
        XCTAssertEqual(b.timeIntervalSince(a), 25 * 3600, "08:00 stays 08:00 on the clock")
    }

    func testDescriptions() {
        XCTAssertEqual(TaskSchedule.daily(hour: 8, minute: 5, weekdaysOnly: true).description, L("Elke werkdag om 08:05"))
        XCTAssertEqual(TaskSchedule.every(hours: 1, from: 8, to: 22).description, L("Elk uur, \(L("van 08:00 tot 22:00"))"))
    }
}

@MainActor
final class TaskStoreTests: XCTestCase {
    private func store() -> TaskStore {
        TaskStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testDueOnceAndThenTheNextRun() {
        let s = store()
        let now = Date()
        var t = ScheduledTask(title: "Agenda", prompt: "Wat staat er vandaag?", schedule: .every(hours: 1, from: 0, to: 0))
        s.upsert(t, now: now.addingTimeInterval(-3700))        // planned an hour ago: due
        t = s.tasks[0]
        XCTAssertLessThan(t.nextRun!, now)
        XCTAssertEqual(s.takeDue(now: now).map(\.title), ["Agenda"])
        XCTAssertEqual(s.takeDue(now: now), [], "it comes once")
        XCTAssertGreaterThan(s.tasks[0].nextRun!, now)
        XCTAssertEqual(s.tasks[0].lastRun, now)
        // and it is kept
        let again = TaskStore(file: s.file)
        XCTAssertEqual(again.tasks.map(\.title), ["Agenda"])
    }

    func testMissedByTooMuchIsSkipped() {
        let s = store()
        let now = Date()
        s.upsert(ScheduledTask(title: "Ochtend", prompt: "x", schedule: .daily(hour: 8, minute: 0, weekdaysOnly: false)),
                 now: now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(s.takeDue(now: now), [], "three days late: not made up for")
        XCTAssertNotNil(s.tasks[0].lastSkipped)
        XCTAssertGreaterThan(s.tasks[0].nextRun!, now)
    }

    func testASingleRunSwitchesItselfOff() {
        let s = store()
        let now = Date()
        s.upsert(ScheduledTask(title: "Eén keer", prompt: "x", schedule: .once(now.addingTimeInterval(60))), now: now)
        XCTAssertEqual(s.takeDue(now: now.addingTimeInterval(61)).count, 1)
        XCTAssertFalse(s.tasks[0].enabled)
        XCTAssertNil(s.tasks[0].nextRun)
    }

    func testOffMeansNoRun() {
        let s = store()
        var t = ScheduledTask(title: "Uit", prompt: "x", schedule: .every(hours: 1, from: 0, to: 0))
        t.enabled = false
        s.upsert(t, now: Date().addingTimeInterval(-7200))
        XCTAssertNil(s.tasks[0].nextRun)
        XCTAssertEqual(s.takeDue(), [])
    }
}
