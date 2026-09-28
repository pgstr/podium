// WireMappingStreamTests.swift — round-trips for the streaming DTOs:
// stats sweeps and events. Same contract as WireMappingTests: lossless for
// every field a formatter reads.

import Foundation
import PodiumCore
import PodiumDaemon
import XCTest

@testable import PodiumRPC

final class WireMappingStreamTests: XCTestCase {

    func testStatsSampleRoundTrip() {
        let sweep = [
            Reconciler.StatSample(id: "web", state: "running",
                                  cpuUsageUsec: 5_000_000, sampledAtUsec: 77_000_000,
                                  memUsageBytes: 64 << 20, memLimitBytes: 512 << 20,
                                  cpus: 2, cpuPct: nil),
            Reconciler.StatSample(id: "cron-job", state: "scheduled",
                                  cpuUsageUsec: nil, sampledAtUsec: 77_000_500,
                                  memUsageBytes: nil, memLimitBytes: nil,
                                  cpus: 1, cpuPct: nil),
        ]
        let frame = PbStatsSample(sweep)
        XCTAssertEqual(frame.sampledAtUsec, 77_000_000, "frame timestamp = first row's clock")
        let back = frame.wireSamples

        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].id, "web")
        XCTAssertEqual(back[0].state, "running")
        XCTAssertEqual(back[0].cpuUsageUsec, 5_000_000)
        XCTAssertEqual(back[0].memUsageBytes, 64 << 20)
        XCTAssertEqual(back[0].memLimitBytes, 512 << 20)
        XCTAssertEqual(back[0].cpus, 2)
        // Row timestamps collapse to frame level — that's the documented loss.
        XCTAssertEqual(back[1].sampledAtUsec, 77_000_000)
        // has_cpu / has_mem guards: nils survive, not zeros.
        XCTAssertNil(back[1].cpuUsageUsec)
        XCTAssertNil(back[1].memUsageBytes)
        XCTAssertNil(back[1].memLimitBytes)
        // cpuPct never rides the wire.
        XCTAssertNil(back[0].cpuPct)
    }

    func testStatsZeroCpuIsPreservedByGuard() {
        // A container at 0 cumulative µs (just started) must not decode as nil.
        let sweep = [Reconciler.StatSample(id: "web", state: "running",
                                           cpuUsageUsec: 0, sampledAtUsec: 1,
                                           memUsageBytes: nil, memLimitBytes: nil,
                                           cpus: 1, cpuPct: nil)]
        XCTAssertEqual(PbStatsSample(sweep).wireSamples[0].cpuUsageUsec, 0)
    }

    func testEventRoundTrip() {
        let t = Date(timeIntervalSince1970: 1_752_300_000.123456)
        let e = PodiumEvent(seq: 42, timestamp: t, stack: "demo", svc: "web",
                            type: "backoff", detail: "backoff 4s (attempt 2/5)", generation: 7)
        let back = PbEvent(e).wire
        XCTAssertEqual(back.seq, 42)
        XCTAssertEqual(back.timestamp.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(back.stack, "demo")
        XCTAssertEqual(back.svc, "web")
        XCTAssertEqual(back.type, "backoff")
        XCTAssertEqual(back.detail, "backoff 4s (attempt 2/5)")
        XCTAssertEqual(back.generation, 7)
    }

    func testEventNilDetailAndZeroGeneration() {
        let e = PodiumEvent(seq: 1, timestamp: Date(timeIntervalSince1970: 1), stack: "s",
                            svc: "web", type: "started", detail: nil)
        let back = PbEvent(e).wire
        XCTAssertNil(back.detail, "empty string on the wire must decode as nil")
        XCTAssertEqual(back.generation, 0)
    }

    func testAuditMetadataRoundTrips() {
        let e = PodiumEvent(
            seq: 9, timestamp: Date(timeIntervalSince1970: 1), stack: "s",
            svc: "@stack", type: "audit", detail: "down", generation: 0,
            auditUser: "alice", auditArgv: "podium down")
        let back = PbEvent(e).wire
        XCTAssertEqual(back.auditUser, "alice")
        XCTAssertEqual(back.auditArgv, "podium down")
    }
}
