// StubBackend.swift — canned ControlPlaneBackend for service tests. Knows
// two services ("web" running, "cron-job" scheduled) and one stack shape;
// reload/diff answers are fixed. No reconciler, no runtime.

import Foundation
import PodiumCore
import PodiumDaemon

struct StubBackend: ControlPlaneBackend {
    static let t0 = Date(timeIntervalSince1970: 1_752_300_000)

    /// Thrown by reloadFromDisk when `failReload` is set.
    struct BrokenStack: Error, CustomStringConvertible {
        var description: String { "stack file is broken" }
    }

    struct BrokenExec: Error, CustomStringConvertible {
        var description: String { "exec startup is broken" }
    }

    var failReload = false
    var failExec = false

    struct AuditEntry: Equatable {
        let action: AuditAction
        let serviceID: String?
        let user: String
        let argv: String
    }
    let auditLog = AuditLog()
    final class AuditLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [AuditEntry] = []
        func add(_ entry: AuditEntry) { lock.lock(); entries.append(entry); lock.unlock() }
        var all: [AuditEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func recordAudit(action: AuditAction, serviceID: String?, user: String, argv: String) async {
        auditLog.add(AuditEntry(action: action, serviceID: serviceID, user: user, argv: argv))
    }

    func snapshot() async -> [ServiceStatus] {
        [
            ServiceStatus(id: "web", state: "running", ready: true, starts: 2,
                          startedAt: Self.t0, ip: "192.168.64.5",
                          portForwards: [PortForward(host: 8080, container: 80)]),
            ServiceStatus(id: "cron-job", state: "scheduled", ready: false, starts: 4,
                          startedAt: nil, schedule: "0 2 * * *",
                          lastRun: Self.t0, lastExit: 0,
                          nextRun: Self.t0.addingTimeInterval(3600)),
        ]
    }

    func describe(_ id: String) async -> Reconciler.DescribeResult? {
        guard id == "web" else { return nil }
        return Reconciler.DescribeResult(
            id: "web", stack: "stubstack", state: "running", ready: true, starts: 2,
            startedAt: Self.t0, ip: "192.168.64.5",
            portForwards: [PortForward(host: 8080, container: 80)],
            image: "nginx:1.27", cpus: 2, memoryMB: 512, rootfsGB: 1,
            command: nil, volumes: [], env: ["FOO": "bar"],
            healthCheck: ["curl", "-f", "http://localhost/"], livenessCheck: nil,
            restartPolicy: "always", logPath: "/stub/web.log",
            schedule: nil, lastRun: nil, lastExit: nil, nextRun: nil,
            failReason: nil)
    }

    func stop(_ id: String) async -> Bool { id == "web" || id == "cron-job" }
    func start(_ id: String) async -> Bool { id == "web" || id == "cron-job" }
    func restart(_ id: String) async -> Bool { id == "web" || id == "cron-job" }

    func reloadFromDisk(dryRun: Bool) async throws -> StackDiff {
        if failReload { throw BrokenStack() }
        // Distinguishable shapes so tests can tell diff from reload.
        return dryRun
            ? StackDiff(started: [], stopped: [], restarted: ["web"], unchanged: ["cron-job"])
            : StackDiff(started: ["new-svc"], stopped: [], restarted: [], unchanged: ["web", "cron-job"])
    }

    // MARK: stats sweeps and the event feed

    /// Frame counter shared across sweeps so stream tests see the CPU
    /// counter advance between frames (1 s of cumulative CPU per sweep).
    let sweeps = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n: UInt64 = 0
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    func stats() async -> [Reconciler.StatSample] {
        let n = sweeps.next()
        return [
            Reconciler.StatSample(id: "web", state: "running",
                                  cpuUsageUsec: n * 1_000_000, sampledAtUsec: n * 2_000_000,
                                  memUsageBytes: 64 << 20, memLimitBytes: 512 << 20,
                                  cpus: 2, cpuPct: nil),
            Reconciler.StatSample(id: "cron-job", state: "scheduled",
                                  cpuUsageUsec: nil, sampledAtUsec: n * 2_000_000,
                                  memUsageBytes: nil, memLimitBytes: nil,
                                  cpus: 1, cpuPct: nil),
        ]
    }

    func metrics() async -> PodiumMetrics {
        PodiumMetrics(
            stack: "stubstack", daemonUptimeSeconds: 42.5,
            services: [
                .init(id: "web", phase: "running", starts: 2, restarts: 1,
                      probeLatencySeconds: 0.012, relayConnections: 9),
                .init(id: "cron-job", phase: "scheduled", starts: 4, restarts: 3,
                      probeLatencySeconds: nil, relayConnections: 0),
            ])
    }

    /// Event feed: fixed backlog plus test-pushed live events (see `push`).
    let eventFeed = EventFeed()

    final class EventFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var backlog: [PodiumEvent] = [
            PodiumEvent(seq: 1, timestamp: StubBackend.t0, stack: "stubstack",
                        svc: "web", type: "started", detail: nil, generation: 1),
            PodiumEvent(seq: 2, timestamp: StubBackend.t0.addingTimeInterval(5), stack: "stubstack",
                        svc: "cron-job", type: "scheduled", detail: "0 2 * * *", generation: 1),
        ]
        private var continuations: [AsyncStream<PodiumEvent>.Continuation] = []

        func events(after seq: Int) -> [PodiumEvent] {
            lock.lock(); defer { lock.unlock() }
            return backlog.filter { $0.seq > seq }
        }

        func stream(after seq: Int) -> AsyncStream<PodiumEvent> {
            let (stream, cont) = AsyncStream.makeStream(of: PodiumEvent.self, bufferingPolicy: .unbounded)
            lock.lock(); defer { lock.unlock() }
            for e in backlog where e.seq > seq { cont.yield(e) }
            continuations.append(cont)
            return stream
        }

        /// Test hook: append + push to live streams, like the reconciler does.
        func push(_ e: PodiumEvent) {
            lock.lock(); defer { lock.unlock() }
            backlog.append(e)
            for c in continuations { c.yield(e) }
        }
    }

    func events(after: Int) async -> [PodiumEvent] { eventFeed.events(after: after) }
    func eventStream(after: Int) async -> AsyncStream<PodiumEvent> { eventFeed.stream(after: after) }

    // MARK: logs

    /// Tests point this at a temp file; "web"/"cron-job" resolve, others don't.
    let logBase = LogBase()
    final class LogBase: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String? = nil
        func set(_ p: String) { lock.lock(); path = p; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return path }
    }

    func logPath(_ id: String) async -> String? {
        guard id == "web" || id == "cron-job" else { return nil }
        return logBase.value ?? "/nonexistent/\(id).log"
    }

    // MARK: scripted exec sessions

    /// Retains every session handed out so tests can inspect what the
    /// service forwarded (stdin, resizes, termination).
    let execLog = ExecLog()

    final class ExecLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sessions: [EchoExecSession] = []
        fileprivate func add(_ s: EchoExecSession) { lock.lock(); sessions.append(s); lock.unlock() }
        var last: EchoExecSession? { lock.lock(); defer { lock.unlock() }; return sessions.last }
    }

    func execSession(_ id: String, argv: [String], tty: Bool,
                     rows: UInt16, cols: UInt16) async throws -> (any ExecSession)? {
        guard id == "web" || id == "cron-job" else { return nil }
        if failExec { throw BrokenExec() }
        let s = EchoExecSession(argv: argv, tty: tty, rows: rows, cols: cols)
        execLog.add(s)
        return s
    }

    // MARK: cp. Models the native transfer with host file ops so the
    // control plane's staging/streaming is exercised end-to-end.

    let copyLog = CopyLog()
    final class CopyLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var imports: [(containerPath: String, mode: UInt32, data: Data)] = []
        private(set) var exports: [String] = []
        func recordImport(_ p: String, _ m: UInt32, _ d: Data) { lock.lock(); imports.append((p, m, d)); lock.unlock() }
        func recordExport(_ p: String) { lock.lock(); exports.append(p); lock.unlock() }
        var lastImport: (containerPath: String, mode: UInt32, data: Data)? {
            lock.lock(); defer { lock.unlock() }; return imports.last
        }
    }

    /// The fixed "file contents" a copyOut of "web" yields.
    static let exportFixture = Data("hello from the container\n".utf8)

    func importFile(_ id: String, hostPath: String, containerPath: String, mode: UInt32) async -> CopyOutcome {
        guard id == "web" || id == "cron-job" else { return .notRunning }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: hostPath)) else {
            return .failed("staging file unreadable")
        }
        copyLog.recordImport(containerPath, mode, data)
        return .ok
    }

    func exportFile(_ id: String, containerPath: String, hostPath: String) async -> CopyOutcome {
        guard id == "web" || id == "cron-job" else { return .notRunning }
        copyLog.recordExport(containerPath)
        do {
            try Self.exportFixture.write(to: URL(fileURLWithPath: hostPath))
            return .ok
        } catch { return .failed("\(error)") }
    }
}

/// Scripted ExecSession: greets on start, echoes stdin to stdout, one
/// stderr chunk on the first echo (non-tty realism), exits 0 on EOF.
/// Everything is recorded for assertions.
final class EchoExecSession: ExecSession, @unchecked Sendable {
    let argv: [String]
    let tty: Bool
    private let lock = NSLock()
    private(set) var receivedStdin: [Data] = []
    private(set) var resizes: [(UInt16, UInt16)] = []
    private(set) var sawEOF = false
    private(set) var terminated = false
    private let continuation: AsyncStream<ExecChunk>.Continuation
    public let output: ExecOutput

    init(argv: [String], tty: Bool, rows: UInt16, cols: UInt16) {
        self.argv = argv
        self.tty = tty
        (output, continuation) = ExecOutput.makeStream()
        continuation.yield(.stdout(Data("greeting \(rows)x\(cols)\n".utf8)))
    }

    func writeStdin(_ data: Data) async {
        let first = lock.withLock {
            receivedStdin.append(data)
            return receivedStdin.count == 1
        }
        if first && !tty { continuation.yield(.stderr(Data("echo-err\n".utf8))) }
        continuation.yield(.stdout(data))
    }

    func stdinEOF() async {
        lock.withLock { sawEOF = true }
        continuation.yield(.exit(0))
        continuation.finish()
    }

    func resize(rows: UInt16, cols: UInt16) async {
        lock.withLock { resizes.append((rows, cols)) }
    }

    func terminate() async {
        lock.withLock { terminated = true }
        continuation.finish()
    }

    var didTerminate: Bool { lock.withLock { terminated } }
}
