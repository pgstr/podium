// EventsTests.swift — events persist across restarts and `-f` clients
// resume via sequence number with no gaps and no duplicates.

import Foundation
import XCTest
@testable import PodiumCore
@testable import PodiumDaemon

final class EventsTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("events-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    func svc(_ id: String) -> ServiceSpec {
        ServiceSpec(id: id, image: "img", command: nil, workingDirectory: nil,
                    env: [:], secrets: [:], cpus: 1, memoryMB: 256, rootfsGB: 1,
                    volumes: [], dependsOn: [], healthCheck: nil, restartPolicy: .always)
    }

    func boot(runtime: MockRuntime) throws -> Reconciler {
        var t = Reconciler.Tuning()
        t.backoffBase = 0.02
        t.backoffCap = 0.04
        t.livenessInterval = .seconds(3600)
        t.healthPollInterval = .milliseconds(10)
        return try Reconciler(stack: Stack(name: "t", services: [svc("web")]),
                              stackPath: "/dev/null", runtime: runtime,
                              store: try StateStore(directory: tmp.appendingPathComponent("state")),
                              tuning: t)
    }

    func testEventsSurviveRestartAndSeqResumesWithoutGapsOrDuplicates() async throws {
        // Incarnation A produces a few events, then dies without shutdown.
        let rtA = MockRuntime()
        let a = try boot(runtime: rtA)
        await a.bootstrap()
        await a.reconcile()
        _ = await a.stop("web")
        let aEvents = await a.getEvents(after: -1)
        XCTAssertFalse(aEvents.isEmpty)
        let aKinds = aEvents.map(\.type)
        XCTAssertTrue(aKinds.contains("starting"))
        XCTAssertTrue(aKinds.contains("started"))
        XCTAssertTrue(aKinds.contains("stopped"))
        let aLastSeq = aEvents.last!.seq

        // Incarnation B: A's events are still there (persisted, not a ring).
        let rtB = MockRuntime()
        let b = try boot(runtime: rtB)
        let recoveredKinds = await b.getEvents(after: -1).map(\.type)
        XCTAssertTrue(recoveredKinds.contains("started"),
                      "events must survive a daemon restart")

        await b.bootstrap()   // web is .stopped (durable intent) — no adoption
        _ = await b.start("web")

        // Resume from A's last seen seq: only B-era events, no gaps, no dups.
        let resumed = await b.getEvents(after: aLastSeq)
        XCTAssertFalse(resumed.isEmpty, "B produced events after aLastSeq")
        let seqs = resumed.map(\.seq)
        XCTAssertEqual(seqs, Array(aLastSeq + 1 ... aLastSeq + seqs.count),
                       "sequence must continue exactly where A stopped — no gaps, no dups")
        XCTAssertTrue(resumed.contains { $0.type == "starting" })

        // Full read has strictly increasing, duplicate-free seqs end to end.
        let all = await b.getEvents(after: -1).map(\.seq)
        XCTAssertEqual(all, all.sorted())
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testCrashEchoIsPersistedAlongsideBackoff() async throws {
        let rt = MockRuntime()
        let r = try boot(runtime: rt)
        await r.bootstrap()
        await r.reconcile()

        rt.live["web"]?.triggerExit(1)
        let deadline = Date().addingTimeInterval(3)
        var sawBackoff = false
        while Date() < deadline {
            let kinds = await r.getEvents(after: -1).map(\.type)
            if kinds.contains("backoff") { sawBackoff = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawBackoff)
        let kinds = await r.getEvents(after: -1).map(\.type)
        XCTAssertTrue(kinds.contains("crashed"),
                      "the raw crash echo must be operator-visible in `events`")
        // The informational echo precedes its transition event.
        let events = await r.getEvents(after: -1)
        let crashedSeq = events.first { $0.type == "crashed" }!.seq
        let backoffSeq = events.first { $0.type == "backoff" }!.seq
        XCTAssertLessThan(crashedSeq, backoffSeq)
    }

    func testAuditMetadataIsDurableAndSingleLine() async throws {
        let a = try boot(runtime: MockRuntime())
        await a.recordAudit(
            action: .down, serviceID: nil,
            user: "alice\nadmin", argv: "podium   down\n--volumes")

        let b = try boot(runtime: MockRuntime())
        let events = await b.getEvents(after: -1)
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.type, "audit")
        XCTAssertEqual(event.svc, "@stack")
        XCTAssertEqual(event.detail, "down")
        XCTAssertEqual(event.auditUser, "alice admin")
        XCTAssertEqual(event.auditArgv, "podium down --volumes")
    }
}
