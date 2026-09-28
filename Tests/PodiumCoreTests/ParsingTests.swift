// ParsingTests.swift — duration parsing, age/next-run formatting, and the
// log-timestamp filter.
import XCTest
@testable import PodiumCore

final class ParsingTests: XCTestCase {

    // MARK: parseDuration

    func testParseDurationValid() {
        XCTAssertEqual(parseDuration("90s"), 90)
        XCTAssertEqual(parseDuration("30m"), 1800)
        XCTAssertEqual(parseDuration("1h"), 3600)
        XCTAssertEqual(parseDuration("1h30m"), 5400)
        XCTAssertEqual(parseDuration("2d"), 172_800)
        XCTAssertEqual(parseDuration("1d2h3m4s"), 86_400 + 7200 + 180 + 4)
    }

    func testParseDurationInvalid() {
        XCTAssertNil(parseDuration(""))       // empty
        XCTAssertNil(parseDuration("10"))     // trailing digits without a unit
        XCTAssertNil(parseDuration("1h30"))   // same, after a valid part
        XCTAssertNil(parseDuration("1x"))     // unknown unit
        XCTAssertNil(parseDuration("h"))      // unit without a number
        XCTAssertNil(parseDuration("m5"))
    }

    // MARK: exec argument parsing

    func testExecAcceptsDocumentedSeparator() {
        XCTAssertEqual(
            parseExecInvocation(["web", "--", "echo", "hello"]),
            ExecInvocation(service: "web", argv: ["echo", "hello"], interactive: false)
        )
    }

    func testExecConsumesOnlyLeadingPodiumFlags() {
        XCTAssertEqual(
            parseExecInvocation(["-i", "-t", "web", "grep", "-i", "needle"]),
            ExecInvocation(service: "web", argv: ["grep", "-i", "needle"], interactive: true)
        )
        XCTAssertEqual(
            parseExecInvocation(["web", "sh", "-t"]),
            ExecInvocation(service: "web", argv: ["sh", "-t"], interactive: false)
        )
    }

    func testExecRequiresServiceAndCommand() {
        XCTAssertNil(parseExecInvocation([]))
        XCTAssertNil(parseExecInvocation(["web"]))
        XCTAssertNil(parseExecInvocation(["web", "--"]))
    }

    // MARK: age / inDuration formatting (deterministic via injected `now`)

    func testAgeFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func ago(_ s: TimeInterval) -> String { age(now.addingTimeInterval(-s), now: now) }
        XCTAssertEqual(ago(8), "8s")
        XCTAssertEqual(ago(45 * 60), "45m")
        XCTAssertEqual(ago(2 * 3600 + 5 * 60), "2h5m")
        XCTAssertEqual(ago(3 * 86_400 + 2 * 3600), "3d2h")
    }

    func testInDurationFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func upcoming(_ s: TimeInterval) -> String { inDuration(now.addingTimeInterval(s), now: now) }
        XCTAssertEqual(upcoming(-5), "now")
        XCTAssertEqual(upcoming(0), "now")
        XCTAssertEqual(upcoming(45), "in 45s")
        XCTAssertEqual(upcoming(45 * 60), "in 45m")
        XCTAssertEqual(upcoming(2 * 3600 + 30 * 60), "in 2h30m")
        XCTAssertEqual(upcoming(2 * 3600), "in 2h")        // zero minutes suppressed
        XCTAssertEqual(upcoming(3 * 86_400), "in 3d")      // zero hours suppressed
        XCTAssertEqual(upcoming(3 * 86_400 + 4 * 3600), "in 3d4h")
    }

    // MARK: parseLogTimestamp ("[yyyy-MM-dd HH:mm:ss] ..." prefix)

    func testLogTimestampRoundTrip() {
        let line = "[2026-07-10 12:34:56] service started"
        guard let ts = parseLogTimestamp(line) else { return XCTFail("no timestamp parsed") }
        // Round-trip through the same format (formatter uses the local zone,
        // matching how the daemon writes the prefix).
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(f.string(from: ts), "2026-07-10 12:34:56")
    }

    func testLogTimestampOrderingHoldsForFiltering() {
        let early = parseLogTimestamp("[2026-07-10 00:00:01] a")!
        let late  = parseLogTimestamp("[2026-07-10 23:59:59] b")!
        XCTAssertLessThan(early, late)
    }

    func testLogTimestampRejectsNonPrefixedLines() {
        XCTAssertNil(parseLogTimestamp("no prefix here"))
        XCTAssertNil(parseLogTimestamp("[short"))
        XCTAssertNil(parseLogTimestamp("[not a date but long enough] x"))
        XCTAssertNil(parseLogTimestamp(""))
        // `logs --since` treats nil as "keep the line" — asserted by the callers'
        // contract; here we only pin the nil cases.
    }
}
