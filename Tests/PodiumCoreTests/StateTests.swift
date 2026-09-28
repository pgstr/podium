// StateTests.swift — illegal transitions throw; every transition
// emits exactly one event. The legality matrix below is exhaustive:
// every (trigger, phase) pair is asserted, so any change to the machine
// must be reflected here deliberately.

import XCTest
@testable import PodiumCore

final class StateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(in phase: ServicePhase, cron: CronState? = nil) -> ServiceRecord {
        ServiceRecord(id: "svc", phase: phase, generation: 3,
                      containerID: phase == .running ? "c-123" : nil,
                      ip: phase == .running ? "192.168.64.5" : nil,
                      starts: 4, consecutiveFails: 1, cron: cron)
    }

    // MARK: Exhaustive legality matrix

    /// Every trigger with the exact set of phases it is legal from.
    private var matrix: [(TransitionTrigger, Set<ServicePhase>)] {
        [
            (.startAttempt(user: false), [.pending, .backingOff, .exited, .stopped]),
            (.startAttempt(user: true), [.pending, .backingOff, .exited, .stopped, .failed]),
            (.cronFire, [.scheduled]),
            (.started(containerID: "c-1", ip: "10.0.0.2"), [.starting]),
            (.rollingReplaced(containerID: "c-2", ip: "10.0.0.3"), [.running]),
            (.becameReady, [.running]),
            (.readinessTimedOut, [.running]),
            (.livenessFailed(detail: "probe exit 1"), [.running]),
            (.exited(code: 0, disposition: .complete), [.starting, .running]),
            (.exited(code: 1, disposition: .restart(at: t0, fresh: false)), [.starting, .running]),
            (.exited(code: 1, disposition: .giveUp), [.starting, .running]),
            (.exited(code: 0, disposition: .reschedule(next: t0)), [.starting, .running]),
            (.startFailed(reason: "pull failed", retryAt: t0, initStep: nil), [.starting]),
            (.startFailed(reason: "init exit 2", retryAt: nil, initStep: "migrate"), [.starting]),
            (.userStop, [.pending, .starting, .running, .backingOff, .failed, .exited, .scheduled]),
            (.specRemoved, Set(ServicePhase.allCases)),
            (.adoptionCleanup, [.starting, .running, .backingOff, .failed]),
            (.cronScheduled(next: t0), [.pending]),
        ]
    }

    func testLegalityMatrixIsExhaustive() {
        for (trigger, legalFrom) in matrix {
            for phase in ServicePhase.allCases {
                let r = record(in: phase)
                if legalFrom.contains(phase) {
                    XCTAssertNoThrow(
                        try transition(r, trigger, now: t0),
                        "\(trigger.name) from \(phase.rawValue) should be legal")
                } else {
                    XCTAssertThrowsError(
                        try transition(r, trigger, now: t0),
                        "\(trigger.name) from \(phase.rawValue) should throw") { err in
                        guard let te = err as? TransitionError else {
                            return XCTFail("expected TransitionError, got \(err)")
                        }
                        XCTAssertEqual(te.from, phase)
                        XCTAssertEqual(te.trigger, trigger.name)
                        XCTAssertEqual(te.serviceID, "svc")
                    }
                }
            }
        }
    }

    // MARK: Exactly one event, of the right kind

    func testEveryLegalTransitionEmitsExactlyOneEventOfExpectedKind() throws {
        // The return type already guarantees "exactly one"; pin the kinds.
        let expected: [(TransitionTrigger, ServicePhase, EventKind)] = [
            (.startAttempt(user: false), .pending, .starting),
            (.startAttempt(user: true), .failed, .starting),
            (.cronFire, .scheduled, .cronFired),
            (.started(containerID: "c-1", ip: nil), .starting, .started),
            (.rollingReplaced(containerID: "c-2", ip: "10.0.0.3"), .running, .started),
            (.becameReady, .running, .healthy),
            (.readinessTimedOut, .running, .unready),
            (.livenessFailed(detail: "x"), .running, .unhealthy),
            (.exited(code: 0, disposition: .complete), .running, .exited),
            (.exited(code: 137, disposition: .complete), .running, .crashed),
            (.exited(code: 1, disposition: .restart(at: t0, fresh: false)), .running, .backoff),
            (.exited(code: 1, disposition: .giveUp), .running, .failed),
            (.exited(code: 0, disposition: .reschedule(next: t0)), .running, .cronDone),
            (.startFailed(reason: "r", retryAt: t0, initStep: nil), .starting, .backoff),
            (.startFailed(reason: "r", retryAt: nil, initStep: nil), .starting, .failed),
            (.userStop, .running, .stopped),
            (.specRemoved, .scheduled, .stopped),
            (.adoptionCleanup, .backingOff, .adoptedCleanup),
            (.cronScheduled(next: t0), .pending, .scheduled),
        ]
        for (trigger, from, kind) in expected {
            let (post, event) = try transition(record(in: from), trigger, now: t0)
            XCTAssertEqual(event.kind, kind, "\(trigger.name) from \(from.rawValue)")
            XCTAssertEqual(event.serviceID, "svc")
            XCTAssertEqual(event.generation, post.generation,
                           "event must carry the POST-transition generation")
        }
    }

    // MARK: Rule 2 — failed is only exited via explicit user start

    func testFailedRequiresUserStart() throws {
        let failed = record(in: .failed)
        XCTAssertThrowsError(try transition(failed, .startAttempt(user: false)))
        let (r, _) = try transition(failed, .startAttempt(user: true), now: t0)
        XCTAssertEqual(r.phase, .starting)
        XCTAssertNil(r.stopReason, "user start clears the stop reason")
        XCTAssertEqual(r.consecutiveFails, 0, "user start is a fresh chance")
    }

    func testAutoStartKeepsTheCrashStreak() throws {
        let (r, _) = try transition(record(in: .backingOff), .startAttempt(user: false), now: t0)
        XCTAssertEqual(r.consecutiveFails, 1, "auto restart must keep counting toward the budget")
    }

    // MARK: Rule 1 — generation is the anti-race token

    func testStartBumpsGenerationAndCounters() throws {
        let (r, e) = try transition(record(in: .backingOff), .startAttempt(user: false), now: t0)
        XCTAssertEqual(r.generation, 4)
        XCTAssertEqual(r.starts, 5)
        XCTAssertEqual(r.lastStartAt, t0)
        XCTAssertNil(r.nextStartAt, "backoff gate cleared on start")
        XCTAssertEqual(e.generation, 4, "watchers must capture the new generation")
    }

    func testNonStartTransitionsDoNotBumpGeneration() throws {
        for (trigger, from): (TransitionTrigger, ServicePhase) in [
            (.becameReady, .running),
            (.exited(code: 0, disposition: .complete), .running),
            (.userStop, .running),
            (.adoptionCleanup, .running),
        ] {
            let (r, _) = try transition(record(in: from), trigger, now: t0)
            XCTAssertEqual(r.generation, 3, "\(trigger.name) must not bump generation")
        }
    }

    // MARK: Runtime identity and readiness

    func testStartedAttachesRuntimeIdentity() throws {
        let (r, _) = try transition(
            record(in: .starting), .started(containerID: "c-9", ip: "10.0.0.7"), now: t0)
        XCTAssertEqual(r.phase, .running)
        XCTAssertEqual(r.containerID, "c-9")
        XCTAssertEqual(r.ip, "10.0.0.7")
        XCTAssertEqual(r.readiness, .unknown)
    }

    func testRollingReplacementAtomicallyAdvancesRunningIdentity() throws {
        let (r, event) = try transition(
            record(in: .running),
            .rollingReplaced(containerID: "c-roll-4", ip: "10.0.0.9"), now: t0)
        XCTAssertEqual(r.phase, .running)
        XCTAssertEqual(r.generation, 4)
        XCTAssertEqual(r.starts, 5)
        XCTAssertEqual(r.containerID, "c-roll-4")
        XCTAssertEqual(r.ip, "10.0.0.9")
        XCTAssertEqual(r.readiness, .passing)
        XCTAssertEqual(event.detail, "rolling update")
    }

    func testExitClearsRuntimeIdentity() throws {
        let (r, _) = try transition(
            record(in: .running), .exited(code: 1, disposition: .restart(at: t0, fresh: false)), now: t0)
        XCTAssertNil(r.containerID)
        XCTAssertNil(r.ip)
        XCTAssertEqual(r.readiness, .unknown)
    }

    func testReadyDoesNotResetFailBudgetAndTimeoutIsVisible() throws {
        let (ready, _) = try transition(record(in: .running), .becameReady, now: t0)
        XCTAssertEqual(ready.readiness, .passing)
        // Readiness can be instant (no-healthcheck services), so
        // resetting the budget here would let a fast-ready crash-looper evade
        // maxRetries forever. The reset is exit-time via .restart(fresh: true).
        XCTAssertEqual(ready.consecutiveFails, 1)

        let (unready, _) = try transition(record(in: .running), .readinessTimedOut, now: t0)
        XCTAssertEqual(unready.readiness, .timedOut(after: t0))
        XCTAssertEqual(unready.phase, .running, "timeout is a visible state, not a kill")
    }

    // MARK: Exit dispositions

    func testRestartDispositionParksInBackoff() throws {
        let retryAt = t0.addingTimeInterval(4)
        let (r, e) = try transition(
            record(in: .running), .exited(code: 3, disposition: .restart(at: retryAt, fresh: false)), now: t0)
        XCTAssertEqual(r.phase, .backingOff)
        XCTAssertEqual(r.nextStartAt, retryAt)
        XCTAssertEqual(r.consecutiveFails, 2)
        XCTAssertEqual(e.detail, "exit 3")
    }

    func testFreshRestartStartsANewFailureStreak() throws {
        // Uptime ≥ stableSeconds (the caller's rule) → this exit is a fresh
        // failure: the streak restarts at 1 instead of accumulating.
        let (r, _) = try transition(
            record(in: .running),  // record fixture has consecutiveFails: 1
            .exited(code: 1, disposition: .restart(at: t0.addingTimeInterval(1), fresh: true)),
            now: t0)
        XCTAssertEqual(r.phase, .backingOff)
        XCTAssertEqual(r.consecutiveFails, 1)
    }

    func testGiveUpSetsCrashLoopReason() throws {
        let (r, _) = try transition(
            record(in: .running), .exited(code: 137, disposition: .giveUp), now: t0)
        XCTAssertEqual(r.phase, .failed)
        XCTAssertEqual(r.stopReason, .crashLoop(exit: 137))
    }

    func testCleanCompleteResetsFailCounter() throws {
        let (r, _) = try transition(
            record(in: .running), .exited(code: 0, disposition: .complete), now: t0)
        XCTAssertEqual(r.phase, .exited)
        XCTAssertEqual(r.consecutiveFails, 0)
    }

    // MARK: Start failures

    func testInitFailureIsTerminalWithStep() throws {
        let (r, e) = try transition(
            record(in: .starting),
            .startFailed(reason: "init 'migrate' exit 2", retryAt: nil, initStep: "migrate"),
            now: t0)
        XCTAssertEqual(r.phase, .failed)
        XCTAssertEqual(r.stopReason, .initFailed(step: "migrate"))
        XCTAssertEqual(e.kind, .failed)
    }

    func testRetryableStartFailureBacksOff() throws {
        let retryAt = t0.addingTimeInterval(8)
        let (r, _) = try transition(
            record(in: .starting),
            .startFailed(reason: "pull failed", retryAt: retryAt, initStep: nil),
            now: t0)
        XCTAssertEqual(r.phase, .backingOff)
        XCTAssertEqual(r.nextStartAt, retryAt)
        XCTAssertEqual(r.stopReason, nil, "still retrying — not stopped")
    }

    // MARK: Cron lifecycle

    func testCronLifecycleEndToEnd() throws {
        let fire = t0.addingTimeInterval(60)
        let next = t0.addingTimeInterval(120)

        var r = ServiceRecord(id: "job")
        var e: StateEvent

        (r, e) = try transition(r, .cronScheduled(next: fire), now: t0)
        XCTAssertEqual(r.phase, .scheduled)
        XCTAssertEqual(r.nextStartAt, fire)
        XCTAssertEqual(e.kind, .scheduled)

        (r, e) = try transition(r, .cronFire, now: fire)
        XCTAssertEqual(r.phase, .starting)
        XCTAssertEqual(r.generation, 1)
        XCTAssertEqual(r.starts, 1)
        XCTAssertEqual(r.cron?.lastRun, fire)

        (r, _) = try transition(r, .started(containerID: "c-j", ip: nil), now: fire)
        (r, e) = try transition(r, .exited(code: 0, disposition: .reschedule(next: next)), now: fire)
        XCTAssertEqual(r.phase, .scheduled)
        XCTAssertEqual(r.nextStartAt, next)
        XCTAssertEqual(r.cron?.lastExit, 0)
        XCTAssertEqual(e.kind, .cronDone)
    }

    // MARK: Stops

    func testUserStopRecordsReasonAndStopOfStoppedThrows() throws {
        let (r, _) = try transition(record(in: .running), .userStop, now: t0)
        XCTAssertEqual(r.phase, .stopped)
        XCTAssertEqual(r.stopReason, .user)
        XCTAssertNil(r.containerID)
        XCTAssertThrowsError(try transition(r, .userStop, now: t0),
                             "stopping a stopped service surfaces an error")
    }

    func testSpecRemovalIsLegalFromEveryPhase() throws {
        for phase in ServicePhase.allCases {
            let (r, e) = try transition(record(in: phase), .specRemoved, now: t0)
            XCTAssertEqual(r.phase, .stopped)
            XCTAssertEqual(r.stopReason, .spec)
            XCTAssertEqual(e.kind, .stopped)
        }
    }

    // MARK: Adoption

    func testAdoptionCleanupReturnsToPending() throws {
        let (r, e) = try transition(record(in: .running), .adoptionCleanup, now: t0)
        XCTAssertEqual(r.phase, .pending)
        XCTAssertNil(r.containerID)
        XCTAssertEqual(e.kind, .adoptedCleanup)
        XCTAssertEqual(r.generation, 3, "adoption is not a start")
        XCTAssertEqual(r.starts, 4, "starts counter continuous across daemon crash")
    }

    func testAdoptionCleanupResetsFailedForAFreshChance() throws {
        let failed = ServiceRecord(id: "svc", phase: .failed, generation: 3, starts: 4,
                                   consecutiveFails: 5, stopReason: .crashLoop(exit: 1))
        let (r, e) = try transition(failed, .adoptionCleanup, now: t0)
        XCTAssertEqual(r.phase, .pending)
        XCTAssertEqual(r.consecutiveFails, 0, "a daemon restart restores the restart budget")
        XCTAssertNil(r.stopReason)
        XCTAssertEqual(e.kind, .adoptedCleanup)
    }

    func testAdoptionCleanupIllegalForDeliberatelyDownServices() {
        // A user-stopped or completed service must NOT re-enter the reconcile
        // loop just because the daemon restarted.
        for phase in [ServicePhase.stopped, .exited, .scheduled, .pending] {
            XCTAssertThrowsError(try transition(record(in: phase), .adoptionCleanup, now: t0))
        }
    }

    // MARK: Codable round-trip (snapshot durability depends on it)

    func testRecordCodableRoundTrip() throws {
        var r = ServiceRecord(
            id: "web", phase: .failed, generation: 42,
            containerID: "c-w", ip: "10.1.1.1",
            starts: 7, consecutiveFails: 5,
            lastStartAt: t0, nextStartAt: t0.addingTimeInterval(30),
            readiness: .timedOut(after: t0),
            cron: CronState(lastRun: t0, lastExit: 2),
            stopReason: .initFailed(step: "migrate"))
        var decoded = try JSONDecoder().decode(
            ServiceRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)

        r = ServiceRecord(id: "bare")
        decoded = try JSONDecoder().decode(
            ServiceRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)

        for reason: StopReason in [.user, .spec, .crashLoop(exit: 137),
                                   .initFailed(step: "s"), .startFailed(reason: "x")] {
            let back = try JSONDecoder().decode(
                StopReason.self, from: JSONEncoder().encode(reason))
            XCTAssertEqual(back, reason)
        }
    }

    // MARK: Event kind wire strings stay compatible with Control.swift

    func testEventKindWireStrings() {
        XCTAssertEqual(EventKind.cronFired.rawValue, "cron-fired")
        XCTAssertEqual(EventKind.cronDone.rawValue, "cron-done")
        XCTAssertEqual(EventKind.adoptedCleanup.rawValue, "adopted-cleanup")
        XCTAssertEqual(EventKind.backoff.rawValue, "backoff")
        XCTAssertEqual(EventKind.unready.rawValue, "unready")
    }
}
