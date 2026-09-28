// ReconcilerTests.swift — the reconciler on a scripted mock runtime. Two
// tests target the races generation tokens close:
//
//   reload race — a superseded container's late exit must not be
//        miscounted as a crash of its replacement.
//   stale probe — a probe started for generation N must never kill
//        (or mis-attribute events to) generation N+1.

import Foundation
import XCTest
@testable import PodiumCore
@testable import PodiumDaemon

// MARK: - Scripted runtime

final class MockContainer: RuntimeContainer, @unchecked Sendable {
    let id: String
    let ip: String
    let createdAt = Date()
    /// Deliver an exit (code 0) when stop() is called — like the real runtime.
    /// The reload-race test sets this false to hold the exit back and deliver it late.
    var exitOnStop = true
    /// Health probes fail until this long after creation (parallelism tests
    /// use it to give every service a measurable readiness delay).
    var readyAfter: TimeInterval = 0
    private(set) var killed = false
    private(set) var stopped = false
    /// Scripted exec: (execID, argv) → exit code. Default: everything passes.
    var execHandler: @Sendable (String, [String]) -> Int32 = { _, _ in 0 }

    private let lock = NSLock()
    private var waiter: CheckedContinuation<Int32, Never>?
    private var pendingExit: Int32?
    private var exited = false

    init(id: String, ip: String) {
        self.id = id
        self.ip = ip
    }

    var ipAddress: String? { ip }

    func wait() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let code = pendingExit {
                pendingExit = nil
                lock.unlock()
                cont.resume(returning: code)
                return
            }
            waiter = cont
            lock.unlock()
        }
    }

    /// Test hook: the container exits with `code`; the exit watcher's wait() resumes.
    func triggerExit(_ code: Int32) {
        lock.lock()
        guard !exited else { lock.unlock(); return }
        exited = true
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: code)
        } else {
            pendingExit = code
            lock.unlock()
        }
    }

    func stop() async throws {
        // NSLock.lock() is unavailable in async contexts — scoped form only.
        let deliver = lock.withLock {
            stopped = true
            return exitOnStop
        }
        if deliver { triggerExit(0) }
    }

    func kill() async throws {
        lock.withLock { killed = true }
        triggerExit(137)
    }

    func exec(id execID: String, argv: [String]) async throws -> RuntimeExecResult {
        if Date().timeIntervalSince(createdAt) < readyAfter {
            return RuntimeExecResult(exitCode: 1)   // not "ready" yet
        }
        return RuntimeExecResult(exitCode: execHandler(execID, argv))
    }

    /// Scripted streaming exec: tests plug a factory; default keeps
    /// the protocol-extension throw so Reconciler.execSession maps it to nil.
    var execSessionFactory: (@Sendable (String, [String], Bool, UInt16, UInt16) -> any ExecSession)? = nil
    func startExecSession(id: String, argv: [String], tty: Bool,
                          rows: UInt16, cols: UInt16) async throws -> any ExecSession {
        guard let factory = lock.withLock({ execSessionFactory }) else { throw ExecUnsupportedError() }
        return factory(id, argv, tty, rows, cols)
    }

    func statistics() async throws -> RuntimeStats {
        RuntimeStats(cpuUsageUsec: 1_000, memUsageBytes: 1 << 20, memLimitBytes: 1 << 30)
    }
}

final class MockRelay: PortRelayHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var targetHistory: [String]
    private var isStopped = false

    init(ip: String) { targetHistory = [ip] }

    var targets: [String] { lock.withLock { targetHistory } }
    var stopped: Bool { lock.withLock { isStopped } }
    var canRetarget: Bool { true }

    func retarget(ip: String) -> Bool {
        lock.withLock { targetHistory.append(ip) }
        return true
    }

    func stop() { lock.withLock { isStopped = true } }
}

final class MockRuntime: ContainerRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startOrder: [String] = []
    private(set) var deleted: [String] = []
    private(set) var configs: [RuntimeContainerConfig] = []
    /// Newest live handle per service id.
    private(set) var live: [String: MockContainer] = [:]
    /// Host relays by service, retained so rolling-update tests can inspect cutover.
    private(set) var relays: [String: [MockRelay]] = [:]
    private var nextIP = 2
    /// Service ids whose createAndStart should throw (start-error containment tests).
    var failCreates: Set<String> = []
    /// Scripted init containers: config.id → exit code. Default 0.
    var initExitCodes: [String: Int32] = [:]
    /// Exec script installed on every new container.
    var execHandler: @Sendable (String, [String]) -> Int32 = { _, _ in 0 }
    /// Readiness delay installed on every new container.
    var containerReadyAfter: TimeInterval = 0

    struct CreateFailure: Error {}

    func delete(_ id: String) {
        lock.lock(); deleted.append(id); lock.unlock()
    }

    func createAndStart(_ config: RuntimeContainerConfig) async throws -> any RuntimeContainer {
        try lock.withLock {
            if failCreates.contains(config.id) { throw CreateFailure() }
            let c = MockContainer(id: config.id, ip: "10.0.0.\(nextIP)")
            nextIP += 1
            c.execHandler = execHandler
            c.readyAfter = containerReadyAfter
            startOrder.append(config.id)
            configs.append(config)
            live[config.id] = c
            return c
        }
    }

    func runToCompletion(_ config: RuntimeContainerConfig) async throws -> Int32 {
        lock.withLock { initExitCodes[config.id] ?? 0 }
    }

    func startPortForwards(_ forwards: [PortForward], serviceID: String, ip: String)
        -> [any PortRelayHandle] {
        lock.withLock {
            let created = forwards.map { _ in MockRelay(ip: ip) }
            relays[serviceID] = created
            return created
        }
    }

    func config(for id: String) -> RuntimeContainerConfig? {
        lock.withLock { configs.last { $0.id == id } }
    }
}

struct FixedSecretsProvider: SecretsProvider {
    let values: [String: String]
    func value(for key: String) throws -> String {
        guard let value = values[key] else {
            throw SecretError.missing(key: key, path: "test-secrets")
        }
        return value
    }
}

// MARK: - Tests

final class ReconcilerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: helpers

    func svc(_ id: String, dependsOn: [String] = [], healthCheck: [String]? = nil,
             restartPolicy: RestartPolicy = .always, schedule: String? = nil,
             initContainers: [InitStep] = [], healthTimeoutSeconds: Int = 1,
             image: String = "img", secrets: [String: String] = [:],
             portForwards: [PortForward] = []) -> ServiceSpec {
        ServiceSpec(id: id, image: image, command: nil, workingDirectory: nil,
                    env: [:], secrets: secrets, cpus: 1, memoryMB: 256, rootfsGB: 1,
                    volumes: [], dependsOn: dependsOn,
                    healthCheck: healthCheck, restartPolicy: restartPolicy,
                    initContainers: initContainers, schedule: schedule,
                    portForwards: portForwards,
                    healthTimeoutSeconds: healthTimeoutSeconds)
    }

    /// Fast clocks for tests; never-fresh by default so crash streaks accumulate.
    func fastTuning(maxRetries: Int = 5, stableSeconds: Double = 999) -> Reconciler.Tuning {
        var t = Reconciler.Tuning()
        t.maxRetries = maxRetries
        t.backoffBase = 0.02
        t.backoffCap = 0.04
        t.stableSeconds = stableSeconds
        t.livenessInterval = .seconds(3600)   // probes fire only when tests say so
        t.healthPollInterval = .milliseconds(10)
        return t
    }

    func makeReconciler(_ services: [ServiceSpec], runtime: MockRuntime,
                        tuning: Reconciler.Tuning? = nil,
                        secretsProvider: (any SecretsProvider)? = nil) throws -> Reconciler {
        try Reconciler(stack: Stack(name: "t", services: services), stackPath: "/dev/null",
                       runtime: runtime,
                       store: try StateStore(directory: tmp),
                       tuning: tuning ?? fastTuning(),
                       secretsProvider: secretsProvider)
    }

    /// Poll until `cond` is true or the timeout elapses.
    func waitUntil(timeout: TimeInterval = 3, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await cond()
    }

    func phase(_ r: Reconciler, _ id: String) async -> ServicePhase? {
        await r.records[id]?.phase
    }

    // MARK: streaming exec seam

    func testExecSessionContractAndWiring() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web")], runtime: rt)
        await r.reconcile()

        // Unknown service → nil ("not running" downstream).
        let ghost = try await r.execSession("ghost", argv: ["sh"], tty: false, rows: 0, cols: 0)
        XCTAssertNil(ghost)

        // Runtime startup errors remain distinguishable from "not running".
        do {
            _ = try await r.execSession("web", argv: ["sh"], tty: false, rows: 0, cols: 0)
            XCTFail("expected the runtime's unsupported-exec error")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }

        // Scripted factory: the session comes back and the exec parameters
        // arrive at the runtime intact.
        final class Recorded: @unchecked Sendable {
            let lock = NSLock()
            var argv: [String] = []; var tty = false
            var rows: UInt16 = 0; var cols: UInt16 = 0
        }
        final class NullSession: ExecSession, @unchecked Sendable {
            let output: ExecOutput
            init() {
                let (s, c) = ExecOutput.makeStream()
                output = s
                c.yield(.exit(0)); c.finish()
            }
            func writeStdin(_ data: Data) async {}
            func stdinEOF() async {}
            func resize(rows: UInt16, cols: UInt16) async {}
            func terminate() async {}
        }
        let rec = Recorded()
        rt.live["web"]?.execSessionFactory = { _, argv, tty, rows, cols in
            rec.lock.withLock {
                rec.argv = argv; rec.tty = tty; rec.rows = rows; rec.cols = cols
            }
            return NullSession()
        }
        let s = try await r.execSession("web", argv: ["sh", "-c", "top"], tty: true, rows: 24, cols: 80)
        XCTAssertNotNil(s)
        rec.lock.withLock {
            XCTAssertEqual(rec.argv, ["sh", "-c", "top"])
            XCTAssertTrue(rec.tty)
            XCTAssertEqual(rec.rows, 24)
            XCTAssertEqual(rec.cols, 80)
        }
    }

    // MARK: bring-up basics

    func testBringUpFollowsDependencyOrderAndPersists() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web", dependsOn: ["db"]), svc("db")], runtime: rt)
        await r.reconcile()

        XCTAssertEqual(rt.startOrder, ["db", "web"], "deps start before dependents")
        for id in ["db", "web"] {
            let rec = await r.records[id]
            XCTAssertEqual(rec?.phase, .running)
            XCTAssertEqual(rec?.readiness, .passing)
            XCTAssertEqual(rec?.starts, 1)
            XCTAssertEqual(rec?.generation, 1)
            XCTAssertNotNil(rec?.ip)
        }

        // Persist-first: a second store over the same directory sees the state.
        let verify = try StateStore(directory: tmp)
        let snap = try XCTUnwrap(try verify.load())
        XCTAssertEqual(snap.records["web"]?.phase, .running)
        XCTAssertEqual(snap.records["db"]?.phase, .running)
        let kinds = try verify.loadEvents().map(\.kind)
        XCTAssertTrue(kinds.contains(.starting))
        XCTAssertTrue(kinds.contains(.started))
        XCTAssertTrue(kinds.contains(.healthy))
    }

    func testSplitProcessFieldsReachTheRuntime() async throws {
        let rt = MockRuntime()
        var service = svc("worker")
        service.entrypoint = ["/init", "/wrapper"]
        service.command = ["gateway"]
        service.args = ["run"]
        let r = try makeReconciler([service], runtime: rt)

        await r.reconcile()

        let config = try XCTUnwrap(rt.config(for: "worker"))
        XCTAssertEqual(config.entrypoint, ["/init", "/wrapper"])
        XCTAssertEqual(config.command, ["gateway"])
        XCTAssertEqual(config.args, ["run"])
    }

    func testManagedDNSConfiguresClientsAndRefreshesPeerAddresses() async throws {
        let rt = MockRuntime()
        let name = "dns-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: StackPaths.dir(for: name)) }
        let stack = try JSONDecoder().decode(Stack.self, from: Data("""
        {"name":"\(name)","dns":true,
         "services":[{"id":"app","image":"img"},{"id":"worker","image":"img"}]}
        """.utf8))
        let r = try Reconciler(
            stack: stack, stackPath: "/dev/null", runtime: rt,
            store: try StateStore(directory: tmp), tuning: fastTuning())

        await r.reconcile()

        XCTAssertEqual(rt.startOrder.first, ManagedDNS.serviceID)
        let dnsIP = try XCTUnwrap(rt.live[ManagedDNS.serviceID]?.ip)
        for id in ["app", "worker"] {
            let config = try XCTUnwrap(rt.config(for: id))
            XCTAssertEqual(config.hostEntries, [])
            XCTAssertEqual(config.dns?.nameservers, [dnsIP])
            XCTAssertEqual(config.dns?.searchDomains, [ManagedDNS.domain])
        }

        let oldIPValue = await r.records["app"]?.ip
        let oldIP = try XCTUnwrap(oldIPValue)
        _ = await r.restart("app")
        let newIPValue = await r.records["app"]?.ip
        let newIP = try XCTUnwrap(newIPValue)
        XCTAssertNotEqual(newIP, oldIP)
        let hostsPath = (StackPaths.volumeDir(for: name, name: ManagedDNS.volumeName)
            as NSString).appendingPathComponent("hosts")
        let hosts = try String(contentsOfFile: hostsPath, encoding: .utf8)
        XCTAssertFalse(hosts.contains(oldIP))
        XCTAssertTrue(hosts.contains(newIP))
    }

    func testManagedDNSRestartRebindsEveryRunningClient() async throws {
        let rt = MockRuntime()
        let name = "dns-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: StackPaths.dir(for: name)) }
        let stack = try JSONDecoder().decode(Stack.self, from: Data("""
        {"name":"\(name)","dns":true,
         "services":[{"id":"app","image":"img"},{"id":"worker","image":"img"}]}
        """.utf8))
        let r = try Reconciler(
            stack: stack, stackPath: "/dev/null", runtime: rt,
            store: try StateStore(directory: tmp), tuning: fastTuning())
        await r.reconcile()
        let oldDNSIP = try XCTUnwrap(rt.live[ManagedDNS.serviceID]?.ip)

        _ = await r.restart(ManagedDNS.serviceID)

        let newDNSIP = try XCTUnwrap(rt.live[ManagedDNS.serviceID]?.ip)
        XCTAssertNotEqual(newDNSIP, oldDNSIP)
        for id in ["app", "worker"] {
            let starts = await r.records[id]?.starts
            XCTAssertEqual(starts, 2)
            XCTAssertEqual(rt.config(for: id)?.dns?.nameservers, [newDNSIP])
        }
    }

    func testStartErrorIsContainedPerService() async throws {
        let rt = MockRuntime()
        rt.failCreates = ["bad"]
        let r = try makeReconciler([svc("bad"), svc("good")], runtime: rt)
        await r.reconcile()

        let bad = await r.records["bad"]
        XCTAssertEqual(bad?.phase, .failed)
        if case .startFailed(let reason)? = bad?.stopReason {
            XCTAssertTrue(reason.hasPrefix("start error:"))
        } else {
            XCTFail("expected .startFailed, got \(String(describing: bad?.stopReason))")
        }
        let good = await r.records["good"]
        XCTAssertEqual(good?.phase, .running, "one bad service must not abort the pass")
        // describe surfaces the reason.
        let desc = await r.describe("bad")
        XCTAssertNotNil(desc?.failReason)
    }

    func testInitContainerFailureIsTerminalWithStep() async throws {
        let rt = MockRuntime()
        rt.initExitCodes = ["job-init-0": 2]
        let r = try makeReconciler(
            [svc("job", initContainers: [InitStep(command: ["migrate"])])], runtime: rt)
        await r.reconcile()

        let rec = await r.records["job"]
        XCTAssertEqual(rec?.phase, .failed)
        XCTAssertEqual(rec?.stopReason, .initFailed(step: "1"))
        XCTAssertNil(rt.live["job"], "main container must never start after init failure")
    }

    // MARK: readiness

    func testUnreadyHealthCheckIsVisibleAndGatesDependents() async throws {
        let rt = MockRuntime()
        rt.execHandler = { _, argv in argv == ["ok?"] ? 1 : 0 }   // db's probe never passes
        let r = try makeReconciler(
            [svc("db", healthCheck: ["ok?"], healthTimeoutSeconds: 1),
             svc("web", dependsOn: ["db"])],
            runtime: rt)
        await r.reconcile()

        let db = await r.records["db"]
        XCTAssertEqual(db?.phase, .running)
        if case .timedOut? = db?.readiness {} else {
            XCTFail("expected .timedOut readiness, got \(String(describing: db?.readiness))")
        }
        let statuses = await r.snapshot()
        XCTAssertEqual(statuses.first { $0.id == "db" }?.state, "running")
        XCTAssertEqual(statuses.first { $0.id == "db" }?.ready, false)
        XCTAssertEqual(statuses.first { $0.id == "web" }?.state, "waiting")
        let unready = await r.getEvents(after: -1).contains { $0.type == "unready" }
        XCTAssertTrue(unready, "readiness timeout must be operator-visible (E0.6)")
    }

    // MARK: crash loop / backoff policy

    func testCrashLoopGivesUpAfterMaxRetries() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web")], runtime: rt, tuning: fastTuning(maxRetries: 2))
        await r.reconcile()

        // Crash repeatedly; each restart is a new generation & start count.
        // The wait keys on the STARTS counter, not just the phase: right
        // after triggerExit the record still reads .running for a moment,
        // and re-triggering the same (already exited) container is a no-op —
        // waiting on the counter guarantees the NEXT incarnation is up.
        var expectedStarts = 1
        for _ in 0..<3 {
            let ok = await waitUntil {
                let rec = await r.records["web"]
                return rec?.phase == .failed
                    || (rec?.phase == .running && rec?.starts == expectedStarts)
            }
            XCTAssertTrue(ok, "service neither running (start #\(expectedStarts)) nor failed")
            if await phase(r, "web") == .failed { break }
            rt.live["web"]?.triggerExit(1)
            expectedStarts += 1
        }
        let failed = await waitUntil { await self.phase(r, "web") == .failed }
        XCTAssertTrue(failed, "crash-looping service must reach failed, not restart forever")
        let rec = await r.records["web"]
        XCTAssertEqual(rec?.stopReason, .crashLoop(exit: 1))
        XCTAssertEqual(rec?.starts, 3, "maxRetries 2 → initial + 2 retries")
    }

    func testStableUptimeStartsAFreshFailureStreak() async throws {
        let rt = MockRuntime()
        var t = fastTuning(maxRetries: 10)
        t.stableSeconds = 0.15
        let r = try makeReconciler([svc("web")], runtime: rt, tuning: t)
        await r.reconcile()

        // Two rapid crashes → streak of 2.
        rt.live["web"]?.triggerExit(1)
        _ = await waitUntil {
            let rec = await r.records["web"]
            return rec?.starts == 2 && rec?.phase == .running
        }
        rt.live["web"]?.triggerExit(1)
        _ = await waitUntil {
            let rec = await r.records["web"]
            return rec?.starts == 3 && rec?.phase == .running
        }
        let mid = await r.records["web"]?.consecutiveFails
        XCTAssertEqual(mid, 2)

        // Run past stableSeconds, then crash: the streak restarts at 1 —
        // the uptime rule (NOT reset-on-ready, which instant readiness
        // would defeat; see State.swift ExitDisposition.restart(fresh:)).
        try await Task.sleep(for: .milliseconds(250))
        rt.live["web"]?.triggerExit(1)
        _ = await waitUntil { await r.records["web"]?.starts == 4 }
        let after = await r.records["web"]?.consecutiveFails
        XCTAssertEqual(after, 1, "stable uptime → fresh streak")
    }

    func testRestartPolicyNoStaysDown() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("oneshot", restartPolicy: .no)], runtime: rt)
        await r.reconcile()
        rt.live["oneshot"]?.triggerExit(0)
        let done = await waitUntil { await self.phase(r, "oneshot") == .exited }
        XCTAssertTrue(done)
        await r.reconcile()   // idempotency: must not restart
        let rec = await r.records["oneshot"]
        XCTAssertEqual(rec?.phase, .exited)
        XCTAssertEqual(rec?.starts, 1)
    }

    // MARK: user stop/start

    func testUserStopIsNeverMiscountedAsACrash() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web")], runtime: rt)
        await r.reconcile()

        _ = await r.stop("web")   // transition first, then container stop → exit echo
        try await Task.sleep(for: .milliseconds(100))   // let the watcher's echo land
        let rec = await r.records["web"]
        XCTAssertEqual(rec?.phase, .stopped)
        XCTAssertEqual(rec?.stopReason, .user)
        XCTAssertEqual(rec?.consecutiveFails, 0, "stop echo must not count as a crash")
        let crashEvents = await r.getEvents(after: -1).filter { $0.type == "crashed" || $0.type == "backoff" }
        XCTAssertTrue(crashEvents.isEmpty, "no crash/backoff events from a user stop")

        _ = await r.start("web")
        let rec2 = await r.records["web"]
        XCTAssertEqual(rec2?.phase, .running)
        XCTAssertEqual(rec2?.starts, 2)
        XCTAssertEqual(rec2?.generation, 2)
    }

    // MARK: reload race

    func testReloadRace_lateExitOfReplacedContainerIsDropped() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web")], runtime: rt)
        await r.reconcile()
        let c1 = try XCTUnwrap(rt.live["web"])
        c1.exitOnStop = false   // hold c1's exit back: it will arrive AFTER the reload

        // Reload with a changed spec → stop c1, start replacement c2 (gen 2).
        let newStack = Stack(name: "t", services: [svc("web", image: "img:v2")])
        let diff = try await r.reload(newStack: newStack)
        XCTAssertEqual(diff.restarted, ["web"])
        let c2 = try XCTUnwrap(rt.live["web"])
        XCTAssertFalse(c2 === c1, "reload must have started a replacement container")
        let seqAfterReload = (await r.getEvents(after: -1)).last?.seq ?? -1
        let recAfterReload = await r.records["web"]
        XCTAssertEqual(recAfterReload?.phase, .running)
        XCTAssertEqual(recAfterReload?.generation, 2)

        // THE RACE: c1's exit watcher fires only now, long after gen 2 took over.
        c1.triggerExit(137)
        try await Task.sleep(for: .milliseconds(150))

        let rec = await r.records["web"]
        XCTAssertEqual(rec?.phase, .running, "stale exit must not disturb the replacement")
        XCTAssertEqual(rec?.generation, 2)
        XCTAssertEqual(rec?.consecutiveFails, 0, "pre-E2.3 bug: stale exit bumped the fail count")
        XCTAssertNil(rec?.nextStartAt, "pre-E2.3 bug: stale exit set a backoff gate")
        XCTAssertEqual(rec?.starts, 2)
        let lateEvents = await r.getEvents(after: seqAfterReload)
            .filter { $0.type == "crashed" || $0.type == "backoff" || $0.type == "failed" }
        XCTAssertTrue(lateEvents.isEmpty, "stale exit emitted \(lateEvents)")
        let running = await r.isRunning("web")
        XCTAssertTrue(running)

        // Belt-and-braces: replaying the stale exit directly is also a no-op.
        await r.onExit("web", generation: 1, exitCode: 137)
        let rec2 = await r.records["web"]
        XCTAssertEqual(rec2?.generation, 2)
        XCTAssertEqual(rec2?.consecutiveFails, 0)
    }

    func testReloadRollsPublishedServiceWithoutStoppingListenerFirst() async throws {
        let rt = MockRuntime()
        let port = PortForward(host: 18_080, container: 80)
        let original = svc("web", image: "img:v1", portForwards: [port])
        let r = try makeReconciler([original], runtime: rt)
        await r.reconcile()

        let old = try XCTUnwrap(rt.live["web"])
        let relay = try XCTUnwrap(rt.relays["web"]?.first)
        XCTAssertEqual(relay.targets, [old.ip])

        let replacement = svc("web", image: "img:v2", portForwards: [port])
        let diff = try await r.reload(newStack: Stack(name: "t", services: [replacement]))

        XCTAssertEqual(diff.restarted, ["web"])
        let candidate = try XCTUnwrap(rt.live["web-roll-2"])
        XCTAssertTrue(old.stopped, "old generation stops only after candidate cutover")
        XCTAssertFalse(candidate.stopped)
        XCTAssertFalse(relay.stopped, "the host listener must survive the update")
        XCTAssertEqual(relay.targets, [old.ip, candidate.ip])
        let rec = await r.records["web"]
        XCTAssertEqual(rec?.phase, .running)
        XCTAssertEqual(rec?.readiness, .passing)
        XCTAssertEqual(rec?.generation, 2)
        XCTAssertEqual(rec?.starts, 2)
        XCTAssertEqual(rec?.containerID, "web-roll-2")
        XCTAssertTrue(rt.deleted.contains("web"))

        _ = await r.stop("web")
        XCTAssertTrue(candidate.stopped)
        XCTAssertTrue(rt.deleted.contains("web-roll-2"),
                      "control paths must delete the rolling container's actual ID")
    }

    func testFailedRollingCandidateLeavesOldGenerationServing() async throws {
        let rt = MockRuntime()
        let port = PortForward(host: 18_081, container: 80)
        let original = svc("web", image: "img:v1", portForwards: [port])
        let r = try makeReconciler([original], runtime: rt)
        await r.reconcile()

        let old = try XCTUnwrap(rt.live["web"])
        let relay = try XCTUnwrap(rt.relays["web"]?.first)
        rt.containerReadyAfter = 10
        let bad = svc("web", healthCheck: ["ready"], healthTimeoutSeconds: 1,
                      image: "img:v2", portForwards: [port])

        do {
            _ = try await r.reload(newStack: Stack(name: "t", services: [bad]))
            XCTFail("unhealthy rolling candidate should fail the reload")
        } catch is RollingUpdateError {
            // Expected: candidate cleanup is isolated from the live generation.
        }

        XCTAssertFalse(old.stopped)
        XCTAssertFalse(relay.stopped)
        XCTAssertEqual(relay.targets, [old.ip])
        XCTAssertTrue(rt.live["web-roll-2"]?.stopped ?? false)
        let rec = await r.records["web"]
        XCTAssertEqual(rec?.phase, .running)
        XCTAssertEqual(rec?.generation, 1)
        XCTAssertEqual(rec?.containerID, "web")
        let active = await r.stack
        XCTAssertEqual(active.services.first?.image, "img:v1")
    }

    // MARK: stale liveness probe

    func testStaleProbe_cannotKillOrDefameSuccessorGeneration() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web", healthCheck: ["ping"])], runtime: rt)
        await r.reconcile()
        let c1 = try XCTUnwrap(rt.live["web"])

        _ = await r.restart("web")   // supersede gen 1 → c2, gen 2
        let c2 = try XCTUnwrap(rt.live["web"])
        XCTAssertFalse(c2 === c1)
        let gen = await r.records["web"]?.generation
        XCTAssertEqual(gen, 2)
        let seqBefore = (await r.getEvents(after: -1)).last?.seq ?? -1

        // A probe armed for generation 1 reaches its kill decision late; it
        // must not act on bookkeeping that now belongs to c2.
        await r.livenessKill(id: "web", generation: 1, container: c1, threshold: 3)

        XCTAssertFalse(c1.killed, "stale probe must not fire its kill at all")
        XCTAssertFalse(c2.killed, "successor container must be untouched")
        let staleEvents = await r.getEvents(after: seqBefore)
        XCTAssertTrue(staleEvents.isEmpty, "stale probe emitted \(staleEvents)")
        let rec = await r.records["web"]
        XCTAssertEqual(rec?.phase, .running)

        // Control experiment: the CURRENT generation's kill decision works.
        await r.livenessKill(id: "web", generation: 2, container: c2, threshold: 3)
        XCTAssertTrue(c2.killed)
        let unhealthy = await r.getEvents(after: seqBefore).contains { $0.type == "unhealthy" }
        XCTAssertTrue(unhealthy)
        // The kill's exit takes the normal crash/backoff/restart path.
        let recovered = await waitUntil {
            let rec = await r.records["web"]
            return rec?.generation == 3 && rec?.phase == .running
        }
        XCTAssertTrue(recovered, "post-kill restart must proceed for the live generation")
    }

    // MARK: reload — removed services

    func testReloadRemovedServiceStopsWithSpecReason() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("a"), svc("b")], runtime: rt)
        await r.reconcile()

        let diff = try await r.reload(newStack: Stack(name: "t", services: [svc("a")]))
        XCTAssertEqual(diff.stopped, ["b"])
        XCTAssertEqual(diff.unchanged, ["a"])
        let b = await r.records["b"]
        XCTAssertNil(b, "removed service's record is dropped with its spec")
        let bStopped = rt.live["b"]?.stopped ?? false
        XCTAssertTrue(bStopped)
        let a = await r.records["a"]
        XCTAssertEqual(a?.phase, .running)
        XCTAssertEqual(a?.starts, 1, "unchanged service must not restart on reload")

        let persisted = try XCTUnwrap(try StateStore(directory: tmp).load())
        XCTAssertNil(persisted.records["b"],
                     "removal-only reload must not leave a stale durable record")
    }

    func testReloadRejectsChangingTheRunningStackName() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web")], runtime: rt)
        await r.reconcile()
        let old = try XCTUnwrap(rt.live["web"])

        do {
            _ = try await r.reload(
                newStack: Stack(name: "renamed", services: [svc("web", image: "img:v2")]))
            XCTFail("a live stack cannot move to a different state/socket namespace")
        } catch let error as StackNameChangeError {
            XCTAssertEqual(error.current, "t")
            XCTAssertEqual(error.proposed, "renamed")
        }

        XCTAssertFalse(old.stopped)
        let current = await r.stack
        XCTAssertEqual(current.name, "t")
        XCTAssertEqual(current.services.first?.image, "img")
    }

    // MARK: parallel bring-up + per-service probe tuning

    func testIndependentServicesStartInParallel() async throws {
        // Three independent services, each ~300 ms to readiness. Sequential
        // bring-up needs ≥ 900 ms; a parallel batch needs ~300 ms. The 700 ms
        // assertion leaves slack for slow machines while still ruling out serial.
        let rt = MockRuntime()
        rt.containerReadyAfter = 0.3
        var t = fastTuning()
        t.healthPollInterval = .milliseconds(20)
        let r = try makeReconciler(
            [svc("a", healthCheck: ["ok?"], healthTimeoutSeconds: 5),
             svc("b", healthCheck: ["ok?"], healthTimeoutSeconds: 5),
             svc("c", healthCheck: ["ok?"], healthTimeoutSeconds: 5)],
            runtime: rt, tuning: t)

        let t0 = Date()
        await r.reconcile()
        let elapsed = Date().timeIntervalSince(t0)

        for id in ["a", "b", "c"] {
            let rec = await r.records[id]
            XCTAssertEqual(rec?.phase, .running)
            XCTAssertEqual(rec?.readiness, .passing, "\(id) must be ready")
        }
        XCTAssertLessThan(elapsed, 0.7,
                          "independent branches must come up concurrently (E2.6); took \(elapsed)s")
    }

    func testDependentsStillWaitForDepsUnderParallelBringUp() async throws {
        let rt = MockRuntime()
        rt.containerReadyAfter = 0.15
        var t = fastTuning()
        t.healthPollInterval = .milliseconds(20)
        let r = try makeReconciler(
            [svc("web1", dependsOn: ["db"], healthCheck: ["ok?"], healthTimeoutSeconds: 5),
             svc("web2", dependsOn: ["db"], healthCheck: ["ok?"], healthTimeoutSeconds: 5),
             svc("db", healthCheck: ["ok?"], healthTimeoutSeconds: 5)],
            runtime: rt, tuning: t)
        await r.reconcile()

        XCTAssertEqual(rt.startOrder.first, "db", "the dependency starts in the first batch, alone")
        XCTAssertEqual(Set(rt.startOrder.dropFirst()), ["web1", "web2"],
                       "dependents form the second batch")
        for id in ["db", "web1", "web2"] {
            let phase = await self.phase(r, id)
            XCTAssertEqual(phase, .running)
        }
    }

    func testPerServiceProbeTuningOverridesDaemonDefaults() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web")], runtime: rt)

        var tuned = svc("web")
        tuned.livenessIntervalSeconds = 30
        tuned.livenessFailThreshold = 5
        let effective = await r.effectiveLivenessTuning(for: tuned)
        XCTAssertEqual(effective.interval, .seconds(30))
        XCTAssertEqual(effective.threshold, 5)

        let defaulted = await r.effectiveLivenessTuning(for: svc("web"))
        XCTAssertEqual(defaulted.interval, fastTuning().livenessInterval)
        XCTAssertEqual(defaulted.threshold, fastTuning().livenessFailThreshold)
    }

    // MARK: secret redaction

    func testCanarySecretIsAbsentFromEveryPersistedAndRenderedOutput() async throws {
        let canary = "CANARY-e4-3-never-emit"
        let rt = MockRuntime()
        let provider = FixedSecretsProvider(values: ["api-token": canary])
        let r = try makeReconciler(
            [svc("web", secrets: ["API_TOKEN": "api-token"])],
            runtime: rt, secretsProvider: provider)

        await r.bootstrap()
        await r.reconcile()

        let config = try XCTUnwrap(rt.config(for: "web"))
        XCTAssertTrue(config.env.contains("API_TOKEN=\(canary)"),
                      "the runtime must still receive the actual secret")
        XCTAssertEqual(config.redactions, [canary])

        let maybeDescribe = await r.describe("web")
        let describe = try XCTUnwrap(maybeDescribe)
        let snapshot = await r.snapshot()
        let events = await r.getEvents(after: -1)
        let encoder = JSONEncoder()

        var outputs = [
            CLIRender.describe(describe),
            CLIRender.ps(stack: "t", services: snapshot),
            String(decoding: try encoder.encode(describe), as: UTF8.self),
            String(decoding: try encoder.encode(snapshot), as: UTF8.self),
            String(decoding: try encoder.encode(events), as: UTF8.self),
            events.map { CLIRender.event($0) }.joined(separator: "\n"),
        ]

        // The real log adapter applies this same redactor after assembling a
        // complete line, so runtime write chunk boundaries cannot expose it.
        let redactor = SecretRedactor(values: config.redactions)
        outputs.append(String(decoding: redactor.redact(
            Data("service echoed \(canary)\n".utf8)), as: UTF8.self))
        // Reconciler start failures use this path before writing daemon.log or
        // persisting the failure reason/event.
        outputs.append(redactor.redact("runtime error included \(canary)"))

        for name in ["state.json", "events.jsonl", "spec.applied.json"] {
            let url = tmp.appendingPathComponent(name)
            outputs.append((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }

        let allOutputs = outputs.joined(separator: "\n")
        XCTAssertFalse(allOutputs.contains(canary),
                       "canary secret escaped into an operator-visible output")
        XCTAssertTrue(allOutputs.contains("[REDACTED]"),
                      "the service/daemon log simulations must exercise redaction")
    }

    func testMetricsTrackDurableStartsRestartsAndProbeLatency() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("web", healthCheck: ["ready"])], runtime: rt)
        await r.reconcile()

        var metrics = await r.metrics()
        XCTAssertEqual(metrics.stack, "t")
        XCTAssertGreaterThanOrEqual(metrics.daemonUptimeSeconds, 0)
        XCTAssertEqual(metrics.services.first?.phase, "running")
        XCTAssertEqual(metrics.services.first?.starts, 1)
        XCTAssertEqual(metrics.services.first?.restarts, 0)
        XCTAssertNotNil(metrics.services.first?.probeLatencySeconds)

        _ = await r.restart("web")
        metrics = await r.metrics()
        XCTAssertEqual(metrics.services.first?.starts, 2)
        XCTAssertEqual(metrics.services.first?.restarts, 1)
    }

    // MARK: cron lifecycle

    func testCronManualFireRunsOnceAndReschedules() async throws {
        let rt = MockRuntime()
        let r = try makeReconciler([svc("job", schedule: "* * * * *")], runtime: rt)
        await r.reconcile()   // cron services are not reconcile-driven
        let pending = await phase(r, "job")
        XCTAssertNotEqual(pending, .running)

        _ = await r.start("job")   // manual trigger fires immediately
        let rec = await r.records["job"]
        XCTAssertEqual(rec?.phase, .running)
        XCTAssertNotNil(rec?.cron?.lastRun)
        let fired = await r.getEvents(after: -1).contains { $0.type == "cron-fired" }
        XCTAssertTrue(fired)

        rt.live["job"]?.triggerExit(0)
        let parked = await waitUntil { await self.phase(r, "job") == .scheduled }
        XCTAssertTrue(parked, "finished cron run returns to scheduled, no restart logic")
        let rec2 = await r.records["job"]
        XCTAssertEqual(rec2?.cron?.lastExit, 0)
        let status = await r.snapshot().first { $0.id == "job" }
        XCTAssertEqual(status?.state, "scheduled")
        XCTAssertNotNil(status?.nextRun)
    }
}
