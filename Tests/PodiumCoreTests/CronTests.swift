// CronTests.swift — cron parsing, matching, nextDate, the drift scenario, and
// DST transition behavior.
import XCTest
@testable import PodiumCore

final class CronTests: XCTestCase {

    let utc = TimeZone(identifier: "UTC")!
    let newYork = TimeZone(identifier: "America/New_York")!

    /// Build a Date from components in a given time zone.
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int,
              tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: mo, day: d,
                                             hour: h, minute: mi, second: 0))!
    }

    // MARK: parsing

    func testParseRejectsMalformed() {
        for bad in ["", "* * * *", "* * * * * *",          // field count
                    "60 * * * *", "* 24 * * *",            // out of range
                    "* * 0 * *", "* * * 13 *", "* * * * 8",
                    "*/0 * * * *",                          // zero step
                    "a-b * * * *", "5-1 * * * *",           // bad ranges
                    "1;2 * * * *"] {
            XCTAssertNil(CronSchedule(bad), "accepted: '\(bad)'")
        }
    }

    func testParseAcceptsValidForms() {
        for good in ["* * * * *", "0 3 * * *", "*/5 * * * *", "1-10/2 * * * *",
                     "2/3 * * * *", "0,15,30,45 * * * *", "30 2 1 1 0",
                     "0 0 * * 7"] {
            XCTAssertNotNil(CronSchedule(good), "rejected: '\(good)'")
        }
    }

    // MARK: matching

    func testExactMatch() {
        let s = CronSchedule("5 4 * * *")!
        XCTAssertTrue(s.matches(date(2026, 7, 10, 4, 5, tz: utc), timeZone: utc))
        XCTAssertFalse(s.matches(date(2026, 7, 10, 4, 6, tz: utc), timeZone: utc))
        XCTAssertFalse(s.matches(date(2026, 7, 10, 5, 5, tz: utc), timeZone: utc))
    }

    func testStepAndRangeExpansion() {
        let s = CronSchedule("1-10/3 * * * *")!   // 1,4,7,10
        for m in [1, 4, 7, 10] {
            XCTAssertTrue(s.matches(date(2026, 1, 1, 0, m, tz: utc), timeZone: utc), "\(m)")
        }
        for m in [0, 2, 3, 11, 13] {
            XCTAssertFalse(s.matches(date(2026, 1, 1, 0, m, tz: utc), timeZone: utc), "\(m)")
        }
    }

    func testSundayAliasSevenEqualsZero() {
        // 2026-07-12 is a Sunday.
        let sunday = date(2026, 7, 12, 0, 0, tz: utc)
        XCTAssertTrue(CronSchedule("0 0 * * 0")!.matches(sunday, timeZone: utc))
        XCTAssertTrue(CronSchedule("0 0 * * 7")!.matches(sunday, timeZone: utc))
        let monday = date(2026, 7, 13, 0, 0, tz: utc)
        XCTAssertFalse(CronSchedule("0 0 * * 7")!.matches(monday, timeZone: utc))
    }

    func testDomAndDowBothConstrain() {
        // "0 0 13 * 5" — matches only Friday the 13th (podium requires BOTH,
        // unlike vixie-cron's OR when both are restricted — documented here).
        let s = CronSchedule("0 0 13 * 5")!
        XCTAssertTrue(s.matches(date(2026, 2, 13, 0, 0, tz: utc), timeZone: utc))   // Fri 13 Feb 2026
        XCTAssertFalse(s.matches(date(2026, 4, 13, 0, 0, tz: utc), timeZone: utc))  // Mon 13 Apr 2026
        XCTAssertFalse(s.matches(date(2026, 2, 20, 0, 0, tz: utc), timeZone: utc))  // Friday, not the 13th
    }

    // MARK: nextDate

    func testNextDateIsStrictlyAfter() {
        let s = CronSchedule("*/15 * * * *")!
        let at = date(2026, 7, 10, 12, 15, tz: utc)   // exactly on a boundary
        XCTAssertEqual(s.nextDate(after: at, timeZone: utc),
                       date(2026, 7, 10, 12, 30, tz: utc))
    }

    func testNextDateMidMinuteTruncates() {
        let s = CronSchedule("0 3 * * *")!
        let at = date(2026, 7, 10, 3, 0, tz: utc).addingTimeInterval(30)  // 03:00:30
        XCTAssertEqual(s.nextDate(after: at, timeZone: utc),
                       date(2026, 7, 11, 3, 0, tz: utc))
    }

    // MARK: drift scenario: exactly one fire per matching minute over 6 h

    func testSixHoursOneFirePerMatchingMinute() {
        let s = CronSchedule("*/10 * * * *")!
        let t0 = date(2026, 1, 5, 0, 0, tz: utc)
        let horizon = t0.addingTimeInterval(6 * 3600)
        var fires: [Date] = []
        var cursor = t0
        while let next = s.nextDate(after: cursor, timeZone: utc), next <= horizon {
            fires.append(next)
            cursor = next
        }
        XCTAssertEqual(fires.count, 36, "6 h of */10 → 36 fires")
        XCTAssertEqual(Set(fires).count, fires.count, "no double-fire in any minute")
        for (a, b) in zip(fires, fires.dropFirst()) {
            XCTAssertEqual(b.timeIntervalSince(a), 600, "uniform 10-minute spacing")
        }
    }

    // MARK: DST

    func testDSTSpringForwardSkipsNonexistentSlot() {
        // America/New_York, 2026-03-08: clocks jump 02:00 → 03:00.
        // "30 2 * * *" has no 02:30 that day — the fire is skipped, and the
        // next fire is 02:30 on Mar 9. Wall-clock gap: 23 h (short day) + 2.5 h.
        let s = CronSchedule("30 2 * * *")!
        let midnight = date(2026, 3, 8, 0, 0, tz: newYork)
        let next = s.nextDate(after: midnight, timeZone: newYork)
        XCTAssertEqual(next, date(2026, 3, 9, 2, 30, tz: newYork))
        XCTAssertEqual(next?.timeIntervalSince(midnight), (23 + 2.5) * 3600)
    }

    func testDSTFallBackRepeatedSlotFiresTwice() {
        // America/New_York, 2026-11-01: clocks fall back 02:00 → 01:00, so
        // wall-clock 01:30 occurs at TWO absolute times (EDT then EST), and the
        // minute scan matches both. Documented behavior: the schedule level
        // double-fires here; the daemon's "already fired this minute"
        // guard is what dedupes it (keyed on the wall-clock minute).
        let s = CronSchedule("30 1 * * *")!
        let midnight = date(2026, 11, 1, 0, 0, tz: newYork)
        let first = s.nextDate(after: midnight, timeZone: newYork)!
        XCTAssertEqual(first.timeIntervalSince(midnight), 90 * 60)     // 01:30 EDT
        let second = s.nextDate(after: first, timeZone: newYork)!
        XCTAssertEqual(second.timeIntervalSince(first), 3600)          // 01:30 EST, 1 h later
        let third = s.nextDate(after: second, timeZone: newYork)!
        XCTAssertEqual(third, date(2026, 11, 2, 1, 30, tz: newYork))   // then next day
    }
}
