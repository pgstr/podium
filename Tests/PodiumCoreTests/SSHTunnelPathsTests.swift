// SSHTunnelPathsTests.swift — the pure path math behind `--host`.

import XCTest
@testable import PodiumCore

final class SSHTunnelPathsTests: XCTestCase {

    func testHostTagIsDeterministicAndDistinct() {
        XCTAssertEqual(SSHTunnelPaths.hostTag("mac.example"), SSHTunnelPaths.hostTag("mac.example"),
                       "same host → same tag (needed for master reuse across invocations)")
        XCTAssertNotEqual(SSHTunnelPaths.hostTag("mac.example"), SSHTunnelPaths.hostTag("other.example"))
        XCTAssertNotEqual(SSHTunnelPaths.hostTag("host"), SSHTunnelPaths.hostTag("user@host"),
                       "user@host is a different target than host")
    }

    func testHostTagIsShortHexAndFilesystemSafe() {
        let tag = SSHTunnelPaths.hostTag("some.long.host.name.example.com")
        XCTAssertEqual(tag.count, 16)
        XCTAssertTrue(tag.allSatisfy { $0.isHexDigit }, "tag must be path-safe: \(tag)")
    }

    func testControlPathStaysUnderSunPathBudget() {
        // Even with a long home and a pathological host, ControlPath must fit
        // the macOS sun_path limit (104 bytes) — that's the whole reason we hash.
        let home = "/Users/some-reasonably-long-username"
        let cp = SSHTunnelPaths.controlPath(home: home, host: String(repeating: "x", count: 300))
        XCTAssertLessThan(cp.utf8.count, 104, "ControlPath overflows sun_path: \(cp.utf8.count)")
    }

    func testPathsAreStableAndDistinct() {
        let home = "/Users/tester"
        XCTAssertEqual(SSHTunnelPaths.dir(home: home), "/Users/tester/.podium/ssh")
        let cp = SSHTunnelPaths.controlPath(home: home, host: "mac.example")
        let hc = SSHTunnelPaths.homeCache(home: home, host: "mac.example")
        XCTAssertTrue(cp.hasPrefix("/Users/tester/.podium/ssh/cm-"))
        XCTAssertTrue(cp.hasSuffix(".sock"))
        XCTAssertTrue(hc.hasPrefix("/Users/tester/.podium/ssh/home-"))
        XCTAssertNotEqual(cp, hc)
        // Re-derivation is stable (master/cache are found again next invocation).
        XCTAssertEqual(cp, SSHTunnelPaths.controlPath(home: home, host: "mac.example"))
    }

    func testRemoteHomeProbeDoesNotUseShellQuoting() {
        XCTAssertEqual(
            SSHTunnelPaths.remoteHomeProbeArguments(host: "tester@mac.example"),
            ["tester@mac.example", "printenv", "HOME"]
        )
    }

    func testMasterIsExplicitlyStartedBeforeForwarders() {
        XCTAssertEqual(
            SSHTunnelPaths.masterCheckArguments(host: "mac.example"),
            ["-O", "check", "mac.example"]
        )
        XCTAssertEqual(
            SSHTunnelPaths.masterStartArguments(host: "mac.example"),
            ["-M", "-N", "-f", "mac.example"]
        )
    }
}
