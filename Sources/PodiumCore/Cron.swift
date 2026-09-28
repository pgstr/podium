// Cron.swift — minimal 5-field cron expression matcher.
//
// Format: "minute hour day-of-month month day-of-week"
// Ranges:  0–59   0–23  1–31          1–12  0–7 (0 and 7 = Sunday)
//
// Per-field syntax (comma-separated, combinable):
//   *       match any value
//   n       exact value
//   a-b     inclusive range
//   */n     every n starting from lo  (e.g. */5 = 0,5,10,…)
//   a/n     every n starting from a   (e.g. 2/3 = 2,5,8,…)
//   a-b/n   every n within range      (e.g. 1-10/2 = 1,3,5,7,9)
//
import Foundation

public struct CronSchedule: Sendable {
    private let minutes: Set<Int>   // 0–59
    private let hours:   Set<Int>   // 0–23
    private let doms:    Set<Int>   // 1–31  day-of-month
    private let months:  Set<Int>   // 1–12
    private let dows:    Set<Int>   // 0–6   day-of-week (0 = Sunday)

    public init?(_ expression: String) {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { return nil }
        guard let mins  = Self.expand(fields[0], lo: 0, hi: 59) else { return nil }
        guard let hrs   = Self.expand(fields[1], lo: 0, hi: 23) else { return nil }
        guard let days  = Self.expand(fields[2], lo: 1, hi: 31) else { return nil }
        guard let mons  = Self.expand(fields[3], lo: 1, hi: 12) else { return nil }
        guard let wdays = Self.expand(fields[4], lo: 0, hi:  7) else { return nil }
        minutes = mins; hours = hrs; doms = days; months = mons
        // Normalize: 7 is an alias for Sunday (0).
        dows = wdays.contains(7) ? wdays.union([0]).subtracting([7]) : wdays
    }

    /// Returns the next date strictly after `date` that matches this schedule.
    /// Scans forward minute by minute; searches at most 366 days ahead.
    /// Returns nil only if no match exists within that window (shouldn't happen
    /// for well-formed expressions, but guards against impossible dom+dow combos).
    ///
    /// DST (documented, asserted in CronTests): matching is wall-clock. A slot
    /// that doesn't exist on spring-forward day (e.g. 02:30 when 02:00→03:00 is
    /// skipped) is silently skipped that day; a slot that occurs twice on
    /// fall-back day matches at BOTH absolute times (the schedule level
    /// double-fires; the daemon's per-minute guard dedupes).
    ///
    /// `timeZone` is injectable for tests; production callers use the default.
    public func nextDate(after date: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        // Truncate to the minute boundary in ABSOLUTE time, then advance by
        // 1 minute so we start strictly after `date` (cron fires at minute
        // start, not mid-minute). Deliberately not a components round-trip:
        // Calendar.date(from:) maps an ambiguous fall-back wall-clock time to
        // its first occurrence — up to an hour before `date` — which broke the
        // strictly-after contract. Wall-clock minute boundaries coincide with
        // absolute 60 s boundaries for all whole-minute UTC offsets.
        let secs = date.timeIntervalSinceReferenceDate
        var candidate = Date(timeIntervalSinceReferenceDate: (secs / 60).rounded(.down) * 60 + 60)
        for _ in 0..<(366 * 24 * 60) {
            if matches(candidate, timeZone: timeZone) { return candidate }
            candidate = candidate.addingTimeInterval(60)
        }
        return nil
    }

    /// Returns true if `date` falls within this schedule (minute precision).
    public func matches(_ date: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let min = c.minute, let hr = c.hour,
              let dom = c.day,    let mon = c.month,
              let wd  = c.weekday else { return false }
        let dow = wd - 1  // Calendar: 1=Sun…7=Sat → 0=Sun…6=Sat
        return minutes.contains(min) && hours.contains(hr) &&
               doms.contains(dom)    && months.contains(mon) && dows.contains(dow)
    }

    // MARK: - private parsing

    private static func expand(_ field: String, lo: Int, hi: Int) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            let s = String(part)
            if s == "*" {
                result.formUnion(lo...hi)
                continue
            }
            if let slashIdx = s.firstIndex(of: "/") {
                // base/step  or  a-b/step
                let stepStr = String(s[s.index(after: slashIdx)...])
                let baseStr = String(s[..<slashIdx])
                guard let step = Int(stepStr), step > 0 else { return nil }
                let start: Int
                let end: Int
                if baseStr == "*" {
                    start = lo; end = hi
                } else if let rng = parseRange(baseStr, lo: lo, hi: hi) {
                    start = rng.lowerBound; end = rng.upperBound
                } else if let n = Int(baseStr), n >= lo, n <= hi {
                    start = n; end = hi
                } else { return nil }
                for v in stride(from: start, through: end, by: step) { result.insert(v) }
                continue
            }
            if s.contains("-") {
                guard let rng = parseRange(s, lo: lo, hi: hi) else { return nil }
                result.formUnion(rng)
                continue
            }
            guard let n = Int(s), n >= lo, n <= hi else { return nil }
            result.insert(n)
        }
        return result.isEmpty ? nil : result
    }

    private static func parseRange(_ s: String, lo: Int, hi: Int) -> ClosedRange<Int>? {
        let parts = s.split(separator: "-")
        guard parts.count == 2,
              let a = Int(parts[0]), let b = Int(parts[1]),
              a >= lo, b <= hi, a <= b else { return nil }
        return a...b
    }
}
