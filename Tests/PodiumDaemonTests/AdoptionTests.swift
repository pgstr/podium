// AdoptionTests.swift — startup adoption pass, spec.applied.json, and
// counter continuity across daemon incarnations.
//
// Kill-9 recovery is exercised end-to-end by `podium selftest` on a Mac;
// these tests prove the same recovery logic at the unit level by
// simulating the crash: reconciler A runs and is dropped WITHOUT shutdown,
// reconciler B boots over the same state directory.

import Foundation
import XCTest
@testable import PodiumCore
@testable import PodiumDaemon

final class AdoptionTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("adoption-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    func svc(_ id: String, dependsOn: [String] = [],
             initContainers: [InitStep] = []) -> ServiceSpec {
        ServiceSpec(id: id, image: "img", command: nil, workingDirectory: nil,
                    env: [:], secrets: [:], cpus: 1, memoryMB: 256, rootfsGB: 1,
                    volumes: [], dependsOn: dependsOn,
                    healthCheck: nil, restartPolicy: .always,
                    initContainers: initContainers)
    }

    func fastTuning() -> Reconciler.Tuning {
        var t = Reconciler.Tuning()
        t.backoffBase = 0.02
        t.backoffCap = 0.04
        t.livenessInterval = .seconds(3600)
        t.healthPollInterval = .milliseconds(10)
        return t
    }

    /// Production layout in miniature: state store at <tmp>/state, so
    /// spec.applied.json lands at <tmp>/spec.applied.json — hermetic.
    var stateDir: URL { tmp.appendingPathComponent("state") }

    /// Poll until `cond` is true or the timeout elapses.
    func waitUntil(timeout: TimeInterval = 3, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await cond()
    }

    func boot(_ services: [ServiceSpec], runtime: MockRuntime,
              stackName: String = "t") throws -> Reconciler {
        try Reconciler(stack: Stack(name: stackName, services: services),
                       stackPath: "/dev/null", runtime: runtime,
                       store: try StateStore(directory: stateDir),
                       tuning: fastTuning())
    }

    // MARK: the crash-recovery core (unit-level kill-9)

    func testCrashRecovery_adoptsTearsDownAndKeepsCountersContinuous() async throws {
        // Incarnation A: bring up, then "SIGKILL" (drop with no shutdown).
        let rtA = MockRuntime()
        let a = try boot([svc("web", dependsOn: ["db"]), svc("db")], runtime: rtA)
        await a.bootstrap()
        await a.reconcile()
        let aWeb = await a.records["web"]
        XCTAssertEqual(aWeb?.phase, .running)
        XCTAssertEqual(aWeb?.starts, 1)
        // No shutdown() — records stay .running on disk, exactly like kill -9.

        // Incarnation B boots over the same state directory.
        let rtB = MockRuntime()
        let b = try boot([svc("web", dependsOn: ["db"]), svc("db")], runtime: rtB)

        // Records were recovered, still recorded as running, counters intact.
        for id in ["web", "db"] {
            let rec = await b.records[id]
            XCTAssertEqual(rec?.phase, .running, "pre-bootstrap: recovered as recorded")
            XCTAssertEqual(rec?.starts, 1)
            XCTAssertEqual(rec?.generation, 1)
        }

        await b.bootstrap()
        // Adoption: recorded containers torn down via the only handle we have
        // (the recorded IDs), records parked back in .pending.
        XCTAssertTrue(rtB.deleted.contains("web"), "recorded orphan 'web' must be torn down")
        XCTAssertTrue(rtB.deleted.contains("db"), "recorded orphan 'db' must be torn down")
        for id in ["web", "db"] {
            let rec = await b.records[id]
            XCTAssertEqual(rec?.phase, .pending)
            XCTAssertNil(rec?.containerID)
        }
        let adopted = await b.getEvents(after: -1).filter { $0.type == "adopted-cleanup" }
        XCTAssertEqual(adopted.count, 2, "one adopted-cleanup event per adopted service")

        await b.reconcile()
        for id in ["web", "db"] {
            let rec = await b.records[id]
            XCTAssertEqual(rec?.phase, .running, "converged after recovery")
            XCTAssertEqual(rec?.starts, 2, "starts continuous across the crash (AC)")
            XCTAssertEqual(rec?.generation, 2)
        }
    }

    func testUserIntentSurvivesRestart() async throws {
        // A: web running, db user-stopped, then clean-ish death.
        let rtA = MockRuntime()
        let a = try boot([svc("web"), svc("db")], runtime: rtA)
        await a.bootstrap()
        await a.reconcile()
        _ = await a.stop("db")

        let rtB = MockRuntime()
        let b = try boot([svc("web"), svc("db")], runtime: rtB)
        await b.bootstrap()
        await b.reconcile()

        let web = await b.records["web"]
        XCTAssertEqual(web?.phase, .running, "web adopted and restarted")
        let db = await b.records["db"]
        XCTAssertEqual(db?.phase, .stopped, "user stop is durable intent — restart must not undo it")
        XCTAssertEqual(db?.stopReason, .user)

        // Explicit start still works and resets the streak.
        _ = await b.start("db")
        let db2 = await b.records["db"]
        XCTAssertEqual(db2?.phase, .running)
        XCTAssertEqual(db2?.consecutiveFails, 0)
    }

    func testCrashLoopedServiceGetsFreshBudgetAfterRestart() async throws {
        let rtA = MockRuntime()
        var t = fastTuning()
        t.maxRetries = 1
        t.stableSeconds = 999
        let a = try Reconciler(stack: Stack(name: "t", services: [svc("web")]),
                               stackPath: "/dev/null", runtime: rtA,
                               store: try StateStore(directory: stateDir), tuning: t)
        await a.bootstrap()
        await a.reconcile()
        // Exhaust the budget. Wait on the STARTS counter, not just the phase:
        // right after triggerExit the record still reads .running, and
        // re-triggering the same exited container is a no-op.
        var expectedStarts = 1
        for _ in 0..<2 {
            _ = await waitUntil {
                let rec = await a.records["web"]
                return rec?.phase == .failed
                    || (rec?.phase == .running && rec?.starts == expectedStarts)
            }
            if await a.records["web"]?.phase == .failed { break }
            rtA.live["web"]?.triggerExit(1)
            expectedStarts += 1
        }
        _ = await waitUntil { await a.records["web"]?.phase == .failed }
        let aRec = await a.records["web"]
        XCTAssertEqual(aRec?.phase, .failed)

        let rtB = MockRuntime()
        let b = try boot([svc("web")], runtime: rtB)
        await b.bootstrap()
        await b.reconcile()
        let rec = await b.records["web"]
        XCTAssertEqual(rec?.phase, .running,
                       "a daemon restart (e.g. host reboot) retries a failed service")
        XCTAssertEqual(rec?.consecutiveFails, 0, "restart budget is restored")
        XCTAssertNotNil(rtB.live["web"])
    }

    func testFailedServiceIsRetriedAfterRestart() async throws {
        // A: web's start fails (e.g. VZ refusing to boot during host shutdown)
        // → terminal .failed. The host then reboots.
        let rtA = MockRuntime()
        rtA.failCreates = ["web"]
        let a = try boot([svc("web")], runtime: rtA)
        await a.bootstrap()
        await a.reconcile()
        let aWeb = await a.records["web"]
        XCTAssertEqual(aWeb?.phase, .failed)

        // B: same state directory, the cause is gone.
        let rtB = MockRuntime()
        let b = try boot([svc("web")], runtime: rtB)
        await b.bootstrap()
        let pending = await b.records["web"]
        XCTAssertEqual(pending?.phase, .pending, "failed is not operator intent")
        XCTAssertEqual(pending?.consecutiveFails, 0)
        await b.reconcile()
        let web = await b.records["web"]
        XCTAssertEqual(web?.phase, .running, "a reboot must not strand a failed service")
        XCTAssertNotNil(rtB.live["web"])
    }

    func testStillBrokenServiceFailsAgainAfterRestart() async throws {
        let rtA = MockRuntime()
        rtA.failCreates = ["web"]
        let a = try boot([svc("web")], runtime: rtA)
        await a.bootstrap()
        await a.reconcile()

        let rtB = MockRuntime()
        rtB.failCreates = ["web"]
        let b = try boot([svc("web")], runtime: rtB)
        await b.bootstrap()
        await b.reconcile()
        let web = await b.records["web"]
        XCTAssertEqual(web?.phase, .failed, "genuinely broken services still end up failed")
        XCTAssertEqual(web?.starts, 2)
    }

    func testLeftoverOfRemovedServiceIsTornDown() async throws {
        // A runs web+old; the crash races a spec edit that removes `old`.
        let rtA = MockRuntime()
        let a = try boot([svc("web"), svc("old")], runtime: rtA)
        await a.bootstrap()
        await a.reconcile()
        let oldRec = await a.records["old"]
        XCTAssertEqual(oldRec?.phase, .running)

        // B boots with a spec that no longer contains `old`.
        let rtB = MockRuntime()
        let b = try boot([svc("web")], runtime: rtB)
        await b.bootstrap()
        XCTAssertTrue(rtB.deleted.contains("old"),
                      "recorded container of a removed service must be torn down")
        let gone = await b.records["old"]
        XCTAssertNil(gone, "no record for a service that left the spec")
    }

    func testAppliedSpecIsCommittedAndDriftIsSurvivable() async throws {
        let rtA = MockRuntime()
        let a = try boot([svc("web")], runtime: rtA, stackName: "drift")
        await a.bootstrap()
        let specURL = AppliedSpec.url(stateDirectory: stateDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: specURL.path))
        let applied = AppliedSpec.load(from: specURL)
        XCTAssertEqual(applied?.name, "drift")
        XCTAssertEqual(applied?.services.map { $0.id }, ["web"])

        // B boots with a drifted file (web changed + extra service): must
        // proceed with the file and re-commit it.
        let rtB = MockRuntime()
        let changed = ServiceSpec(id: "web", image: "img:v2", command: nil,
                                  workingDirectory: nil, env: [:], secrets: [:],
                                  cpus: 1, memoryMB: 256, rootfsGB: 1, volumes: [],
                                  dependsOn: [], healthCheck: nil, restartPolicy: .always)
        let b = try boot([changed, svc("extra")], runtime: rtB, stackName: "drift")
        await b.bootstrap()
        await b.reconcile()
        let recommitted = AppliedSpec.load(from: specURL)
        XCTAssertEqual(Set(recommitted?.services.map { $0.id } ?? []), ["web", "extra"])
        let web = await b.records["web"]
        XCTAssertEqual(web?.phase, .running)
        let extra = await b.records["extra"]
        XCTAssertEqual(extra?.phase, .running)
    }

    func testInitContainerOrphansAreTornDownForStartingRecords() async throws {
        // Force a record to be persisted mid-`.starting` by crashing the
        // runtime during create — the record parks in .failed... so instead
        // simulate the .starting snapshot directly: run A with a hanging
        // create is not expressible with the mock, so write the snapshot.
        let store = try StateStore(directory: stateDir)
        var rec = ServiceRecord(id: "web")
        (rec, _) = try transition(rec, .startAttempt(user: false))   // .starting
        try store.save(StateSnapshot(records: ["web": rec]))

        let rtB = MockRuntime()
        let b = try Reconciler(
            stack: Stack(name: "t", services: [svc("web", initContainers: [
                InitStep(command: ["migrate"]), InitStep(command: ["seed"])
            ])]),
            stackPath: "/dev/null", runtime: rtB,
            store: try StateStore(directory: stateDir), tuning: fastTuning())
        await b.bootstrap()
        XCTAssertTrue(rtB.deleted.contains("web-init-0"))
        XCTAssertTrue(rtB.deleted.contains("web-init-1"))
        XCTAssertTrue(rtB.deleted.contains("web-roll-2"))
        XCTAssertTrue(rtB.deleted.contains("web-roll-2-init-0"))
        XCTAssertTrue(rtB.deleted.contains("web-roll-2-init-1"))
        let recovered = await b.records["web"]
        XCTAssertEqual(recovered?.phase, .pending)
        XCTAssertEqual(recovered?.starts, 1, "the interrupted attempt still counts")
    }
}
