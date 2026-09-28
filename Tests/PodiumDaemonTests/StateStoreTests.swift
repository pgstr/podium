// StateStoreTests.swift — a 10k-cycle crash-injection run (kill
// between write and rename, plus every other kill point) never yields a
// corrupt or unreadable state. Crashes are simulated by the store's
// internal one-shot `crashAt` hook, which aborts the operation at the
// injected point exactly as a SIGKILL would leave the filesystem. The
// process-level kill variant is a `podium selftest` phase.

import XCTest
import PodiumCore
@testable import PodiumDaemon

final class StateStoreTests: XCTestCase {

    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-statestore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func snapshot(_ n: Int) -> StateSnapshot {
        var records: [String: ServiceRecord] = [:]
        for i in 0..<(1 + n % 4) {
            var r = ServiceRecord(id: "svc\(i)")
            if i.isMultiple(of: 2), n.isMultiple(of: 3) {
                (r, _) = try! transition(r, .startAttempt(user: false), now: t0)
            }
            records[r.id] = r
        }
        return StateSnapshot(records: records, savedAt: t0.addingTimeInterval(Double(n)))
    }

    private func event(_ n: Int) -> StateEvent {
        StateEvent(kind: n.isMultiple(of: 2) ? .started : .stopped,
                   serviceID: "svc\(n % 3)", generation: UInt64(n),
                   detail: n.isMultiple(of: 5) ? "detail \(n)" : nil)
    }

    // MARK: Basics

    func testFreshStoreLoadsNil() throws {
        XCTAssertNil(try StateStore(directory: dir).load())
    }

    func testSaveLoadRoundTrip() throws {
        let store = try StateStore(directory: dir)
        let snap = snapshot(7)
        try store.save(snap)
        XCTAssertEqual(try store.load(), snap)
        // A separate instance (daemon restart) sees the same state.
        XCTAssertEqual(try StateStore(directory: dir).load(), snap)
    }

    func testTmpFileIsNeverReadAsState() throws {
        let store = try StateStore(directory: dir)
        try store.save(snapshot(1))
        // Torn tmp left behind by a dead writer must be ignored entirely.
        try Data("garbage{{{".utf8).write(to: dir.appendingPathComponent("state.json.tmp"))
        XCTAssertEqual(try store.load(), snapshot(1))
    }

    // MARK: 10k crash-injection cycles

    func testCrashInjection10kCyclesNeverCorruptsState() throws {
        var store = try StateStore(directory: dir)
        store.fsyncEnabled = false  // atomicity logic under test, not the disk
        var rng: UInt64 = 0x5DEECE66D
        func rand(_ bound: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(rng >> 33) % bound
        }
        let points: [CrashPoint?] = [
            nil, nil, nil,  // plenty of clean saves interleaved
            .midTempWrite, .afterTempWrite, .afterRename,
        ]
        var durable: StateSnapshot?  // what a successful load must produce
        for cycle in 0..<10_000 {
            let snap = snapshot(cycle)
            let point = points[rand(points.count)]
            store.crashAt = point
            do {
                try store.save(snap)
                durable = snap
            } catch is SimulatedCrash {
                // afterRename: the rename hit the disk, so the NEW snapshot
                // is what readers see. Everything earlier keeps the old one.
                if point == .afterRename { durable = snap }
            }
            // Simulate the restart: a brand-new store over the same dir.
            if point != nil || cycle.isMultiple(of: 500) {
                store = try StateStore(directory: dir)
                store.fsyncEnabled = false
                let loaded = try store.load()  // must NEVER throw
                XCTAssertEqual(loaded, durable, "cycle \(cycle), crash \(String(describing: point))")
            }
        }
    }

    // MARK: Event log

    func testAppendAssignsMonotonicSeqAcrossReopen() throws {
        let store = try StateStore(directory: dir)
        for n in 0..<5 {
            XCTAssertEqual(try store.append(event(n), at: t0).seq, UInt64(n))
        }
        // Restart: seq continues, no gaps or duplicates.
        let reopened = try StateStore(directory: dir)
        XCTAssertEqual(try reopened.append(event(5), at: t0).seq, 5)
        let all = try reopened.loadEvents()
        XCTAssertEqual(all.map(\.seq), [0, 1, 2, 3, 4, 5])
    }

    func testTornEventTailIsDroppedAndSeqNotBurned() throws {
        var store = try StateStore(directory: dir)
        try store.append(event(0), at: t0)
        try store.append(event(1), at: t0)
        store.crashAt = .midEventAppend
        XCTAssertThrowsError(try store.append(event(2), at: t0)) { XCTAssert($0 is SimulatedCrash) }

        store = try StateStore(directory: dir)
        let events = try store.loadEvents()
        XCTAssertEqual(events.map(\.seq), [0, 1], "torn tail dropped, prefix intact")
        // The torn line's seq is reused — the log stays gap-free.
        XCTAssertEqual(try store.append(event(2), at: t0).seq, 2)
        XCTAssertEqual(try store.loadEvents().map(\.seq), [0, 1, 2])
    }

    func testRotationKeepsSeqContinuityAndOneArchive() throws {
        // Tiny budget forces rotation every few events.
        let store = try StateStore(directory: dir, maxEventLogBytes: 300)
        for n in 0..<40 {
            try store.append(event(n), at: t0)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("events.jsonl.1").path))
        let events = try store.loadEvents()
        // Oldest generations are dropped by design (one archive kept);
        // what remains must be contiguous and end at the newest seq.
        let seqs = events.map(\.seq)
        XCTAssertEqual(seqs.last, 39)
        XCTAssertEqual(seqs, Array(seqs.first!...39).map { UInt64($0) })
        // Restart still recovers the right next seq.
        XCTAssertEqual(try StateStore(directory: dir).append(event(40), at: t0).seq, 40)
    }

    func testCrashMidRotationStaysLoadable() throws {
        var store = try StateStore(directory: dir, maxEventLogBytes: 200)
        for n in 0..<10 {
            try store.append(event(n), at: t0)
        }
        store.crashAt = .midRotation
        var crashed = false
        for n in 10..<30 {
            do {
                try store.append(event(n), at: t0)
            } catch is SimulatedCrash {
                crashed = true
                break
            }
        }
        XCTAssertTrue(crashed, "rotation must have been attempted")
        store = try StateStore(directory: dir, maxEventLogBytes: 200)
        let events = try store.loadEvents()  // must not throw
        XCTAssertFalse(events.isEmpty)
        let seqs = events.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted(), "monotonic after crash")
        _ = try store.append(event(99), at: t0)  // and the log keeps working
    }

    // MARK: Schema version + migration hook

    func testNewerSchemaRefusesWithClearError() throws {
        let store = try StateStore(directory: dir)
        try store.save(snapshot(0))
        let manifest = dir.appendingPathComponent("manifest.json")
        try Data(#"{"schemaVersion":99,"snapshotFile":"state.json"}"#.utf8).write(to: manifest)
        XCTAssertThrowsError(try StateStore(directory: dir).load()) { err in
            guard case StateStoreError.schemaTooNew(let found, let supported) = err else {
                return XCTFail("expected schemaTooNew, got \(err)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, StateStore.schemaVersion)
            XCTAssert("\(err)".contains("upgrade podium"), "error must tell the user what to do")
        }
    }

    func testMigrationHookUpgradesOldSnapshotOnce() throws {
        // Craft a v0 store: no embedded schemaVersion, `services` key instead
        // of `records`.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"services":{},"savedAt":0}"#.utf8)
            .write(to: dir.appendingPathComponent("state.json"))
        try Data(#"{"schemaVersion":0,"snapshotFile":"state.json"}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))

        nonisolated(unsafe) var migrationRuns = 0
        let migrate: [Int: StateStore.Migration] = [
            0: { data in
                migrationRuns += 1
                let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                var new: [String: Any] = ["schemaVersion": 1, "records": obj["services"] ?? [:]]
                new["savedAt"] = obj["savedAt"] ?? 0
                return try JSONSerialization.data(withJSONObject: new)
            },
        ]

        let store = try StateStore(directory: dir, migrations: migrate)
        let snap = try store.load()
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.records, [:])
        XCTAssertEqual(migrationRuns, 1)

        // Second load: manifest + snapshot were rewritten at v1 — the
        // migration must NOT run again (double-migration corrupts).
        let again = try StateStore(directory: dir, migrations: migrate)
        XCTAssertEqual(try again.load(), snap)
        XCTAssertEqual(migrationRuns, 1)
    }

    func testMissingMigrationPathFailsLoudly() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"foo":1}"#.utf8).write(to: dir.appendingPathComponent("state.json"))
        try Data(#"{"schemaVersion":0,"snapshotFile":"state.json"}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try StateStore(directory: dir).load()) { err in
            guard case StateStoreError.noMigration(let from) = err else {
                return XCTFail("expected noMigration, got \(err)")
            }
            XCTAssertEqual(from, 0)
        }
    }
}
