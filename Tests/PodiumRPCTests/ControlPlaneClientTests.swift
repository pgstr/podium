// ControlPlaneClientTests.swift — the CLI's dialing side over the real unix
// socket. Every unary verb goes through ControlPlaneClient.withVerifiedClient
// (dial → GetInfo gate → RPC), so these tests cover the whole path: DTO
// fidelity after the round-trip, error text via .daemon(_), and the
// refuse-on-mismatch version gate.

import Foundation
import GRPCCore
import PodiumCore
import PodiumDaemon
import PodiumRPC
import XCTest

final class ControlPlaneClientTests: XCTestCase {

    /// Short socket paths — a long HOME can push past sun_path.
    private func tempSocketPath() -> String {
        "/tmp/podium-c-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    /// Serves `service` on a fresh socket, runs `body` against it, tears down.
    private func withServer<T: Sendable>(
        service: PodiumControlService,
        _ body: @Sendable @escaping (String) async throws -> T
    ) async throws -> T {
        let path = tempSocketPath()
        defer { unlink(path) }
        let listening = AsyncStream.makeStream(of: Void.self)
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await ControlPlaneServer.serve(
                    socketPath: path, service: service,
                    onListening: { listening.continuation.yield(()) })
                return nil
            }
            group.addTask {
                for await _ in listening.stream { break }
                return try await body(path)
            }
            while let result = try await group.next() {
                if let result { group.cancelAll(); return result }
            }
            group.cancelAll()
            throw XCTSkip("unreachable: server task cannot return first")
        }
    }

    private func stubService(
        failReload: Bool = false,
        failExec: Bool = false,
        protocolVersion: UInt32 = PodiumRPCVersion.protocolVersion
    ) -> PodiumControlService {
        var backend = StubBackend()
        backend.failReload = failReload
        backend.failExec = failExec
        return PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack",
            backend: backend, protocolVersion: protocolVersion)
    }

    // MARK: verbs

    func testListServicesRoundTrip() async throws {
        let (stack, services) = try await withServer(service: stubService()) { path in
            try await ControlPlaneClient.listServices(socketPath: path)
        }
        XCTAssertEqual(stack, "sockstack")
        XCTAssertEqual(services.map(\.id), ["web", "cron-job"])
        let web = services[0]
        XCTAssertEqual(web.state, "running")
        XCTAssertEqual(web.ip, "192.168.64.5")
        XCTAssertEqual(web.portForwards, [PortForward(host: 8080, container: 80)])
        let cron = services[1]
        XCTAssertEqual(cron.schedule, "0 2 * * *")
        XCTAssertEqual(cron.lastExit, 0, "exit 0 must survive the has_last_exit guard")
        XCTAssertEqual(cron.nextRun, StubBackend.t0.addingTimeInterval(3600))
    }

    func testMetricsRoundTrip() async throws {
        let metrics = try await withServer(service: stubService()) { path in
            try await ControlPlaneClient.metrics(socketPath: path)
        }
        XCTAssertEqual(metrics.stack, "sockstack", "stack comes from the verified handshake")
        XCTAssertEqual(metrics.daemonUptimeSeconds, 42.5)
        XCTAssertEqual(metrics.services.count, 2)
        XCTAssertEqual(metrics.services[0].id, "web")
        XCTAssertEqual(metrics.services[0].probeLatencySeconds, 0.012)
        XCTAssertEqual(metrics.services[0].relayConnections, 9)
        XCTAssertNil(metrics.services[1].probeLatencySeconds)
    }

    func testDescribeUsesHandshakeStackName() async throws {
        let d = try await withServer(service: stubService()) { path in
            try await ControlPlaneClient.describe(socketPath: path, id: "web")
        }
        XCTAssertEqual(d.id, "web")
        // The stack name comes from GetInfo (the daemon serves one stack) —
        // not from the backend's DescribeResult, which the proto drops.
        XCTAssertEqual(d.stack, "sockstack")
        XCTAssertEqual(d.image, "nginx:1.27")
        XCTAssertEqual(d.env, ["FOO": "bar"])
        XCTAssertEqual(d.healthCheck, ["curl", "-f", "http://localhost/"])
        XCTAssertNil(d.livenessCheck, "empty repeated must decode as nil")
    }

    func testDescribeUnknownServiceIsDaemonError() async throws {
        do {
            let d = try await withServer(service: stubService()) { path in
                try await ControlPlaneClient.describe(socketPath: path, id: "ghost")
            }
            XCTFail("expected .daemon, got \(d)")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "unknown service", "CLI prints this verbatim after `podium: `")
        }
    }

    func testControlOkAndUnknown() async throws {
        let (ok, bad) = try await withServer(service: stubService()) { path in
            let ok = try await ControlPlaneClient.control(
                socketPath: path, action: .restart, id: "web", argv: "podium restart web")
            let bad = try await ControlPlaneClient.control(
                socketPath: path, action: .stop, id: "ghost", argv: "podium stop ghost")
            return (ok, bad)
        }
        XCTAssertTrue(ok.ok)
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "unknown service")
    }

    func testReloadAndDiffShapes() async throws {
        let (diff, reload) = try await withServer(service: stubService()) { path in
            let diff = try await ControlPlaneClient.reload(
                socketPath: path, dryRun: true, argv: "podium diff")
            let reload = try await ControlPlaneClient.reload(
                socketPath: path, dryRun: false, argv: "podium reload")
            return (diff, reload)
        }
        XCTAssertEqual(diff, StackDiff(started: [], stopped: [], restarted: ["web"], unchanged: ["cron-job"]))
        XCTAssertEqual(reload, StackDiff(started: ["new-svc"], stopped: [], restarted: [], unchanged: ["web", "cron-job"]))
    }

    func testReloadFailureCarriesLegacyText() async throws {
        do {
            let d = try await withServer(service: stubService(failReload: true)) { path in
                try await ControlPlaneClient.reload(socketPath: path, dryRun: false, argv: "podium reload")
            }
            XCTFail("expected .daemon, got \(d)")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "stack file is broken")
        }
    }

    // MARK: streams

    func testStatsStreamPushesFramesOnDaemonSchedule() async throws {
        let started = Date()
        let frames = try await withServer(service: stubService()) { path in
            var out: [ControlPlaneClient.StatsFrame] = []
            for try await f in ControlPlaneClient.statsStream(socketPath: path, intervalMs: 100) {
                out.append(f)
                if out.count == 2 { break }
            }
            return out
        }
        // Two frames well inside a poll-loop's worth of time: the daemon is
        // pushing on its 100 ms schedule, the client sent one request total.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].stack, "sockstack")
        let web0 = frames[0].samples[0], web1 = frames[1].samples[0]
        XCTAssertEqual(web0.id, "web")
        XCTAssertGreaterThan(web1.cpuUsageUsec!, web0.cpuUsageUsec!,
                             "cumulative CPU advances between pushed frames")
        XCTAssertGreaterThan(web1.sampledAtUsec, web0.sampledAtUsec)
        let cron = frames[0].samples[1]
        XCTAssertNil(cron.cpuUsageUsec)
        XCTAssertNil(cron.memUsageBytes)
    }

    func testEventsNoFollowDeliversBacklogAndCompletes() async throws {
        let events = try await withServer(service: stubService()) { path in
            var out: [PodiumEvent] = []
            // No break: the server must end the stream itself after the backlog.
            for try await e in ControlPlaneClient.eventsStream(socketPath: path, after: -1, follow: false) {
                out.append(e)
            }
            return out
        }
        XCTAssertEqual(events.map(\.seq), [1, 2])
        XCTAssertEqual(events[0].type, "started")
        XCTAssertNil(events[0].detail)
        XCTAssertEqual(events[1].detail, "0 2 * * *")
        XCTAssertEqual(events[1].generation, 1)
    }

    func testEventsAfterSeqFiltersBacklog() async throws {
        let events = try await withServer(service: stubService()) { path in
            var out: [PodiumEvent] = []
            for try await e in ControlPlaneClient.eventsStream(socketPath: path, after: 1, follow: false) {
                out.append(e)
            }
            return out
        }
        XCTAssertEqual(events.map(\.seq), [2], "seq 1 is excluded by after=1")
    }

    func testEventsFollowPushesLiveEventFast() async throws {
        var backend = StubBackend()
        backend.failReload = false
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let feed = backend.eventFeed
        let (events, latency) = try await withServer(service: service) { path in
            var out: [PodiumEvent] = []
            var pushedAt: Date? = nil
            var latency: TimeInterval = -1
            for try await e in ControlPlaneClient.eventsStream(socketPath: path, after: -1, follow: true) {
                out.append(e)
                if let t = pushedAt, e.seq == 3 { latency = Date().timeIntervalSince(t) }
                if out.count == 2 {
                    // Backlog delivered and the subscription is live — push.
                    pushedAt = Date()
                    feed.push(PodiumEvent(seq: 3, timestamp: Date(), stack: "stubstack",
                                          svc: "web", type: "crashed", detail: "exit 1", generation: 2))
                }
                if out.count == 3 { break }
            }
            return (out, latency)
        }
        XCTAssertEqual(events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(events[2].type, "crashed")
        XCTAssertEqual(events[2].generation, 2)
        // The path has no sleep anywhere, so this should be milliseconds —
        // 1 s guards against scheduler noise, not the design.
        XCTAssertGreaterThanOrEqual(latency, 0)
        XCTAssertLessThan(latency, 1.0, "live event took \(latency)s — a poll crept back in somewhere")
    }

    // MARK: bidi exec

    private final class OutBox: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [(kind: String, text: String)] = []
        func add(_ o: ControlPlaneClient.ExecOutput) {
            lock.lock(); defer { lock.unlock() }
            switch o {
            case .stdout(let d): chunks.append(("out", String(decoding: d, as: UTF8.self)))
            case .stderr(let d): chunks.append(("err", String(decoding: d, as: UTF8.self)))
            }
        }
        var all: [(kind: String, text: String)] { lock.lock(); defer { lock.unlock() }; return chunks }
    }

    func testExecEchoSessionEndToEnd() async throws {
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let box = OutBox()
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.yield(.stdin(Data("hello".utf8)))
        feed.yield(.eof)
        feed.finish()

        let exit = try await withServer(service: service) { path in
            try await ControlPlaneClient.exec(
                socketPath: path, service: "web", argv: ["cat"],
                tty: false, rows: 24, cols: 80, clientArgv: "podium exec web cat",
                input: input, onOutput: { box.add($0) })
        }
        XCTAssertEqual(exit, 0)
        let chunks = box.all
        XCTAssertEqual(chunks.first?.kind, "out")
        XCTAssertEqual(chunks.first?.text, "greeting 24x80\n")
        XCTAssertTrue(chunks.contains { $0.kind == "err" && $0.text == "echo-err\n" },
                      "stderr rides its own channel for non-tty sessions")
        XCTAssertTrue(chunks.contains { $0.kind == "out" && $0.text == "hello" },
                      "stdin bytes came back on stdout — chunk boundaries preserved")
        let session = try XCTUnwrap(backend.execLog.last)
        XCTAssertEqual(session.argv, ["cat"])
        XCTAssertFalse(session.tty)
        XCTAssertTrue(session.sawEOF)
        XCTAssertEqual(backend.auditLog.all.map(\.action), [.exec])
        XCTAssertEqual(backend.auditLog.all.first?.serviceID, "web")
        XCTAssertEqual(backend.auditLog.all.first?.argv, "podium exec web cat")
    }

    func testExecResizeReachesTheSession() async throws {
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.yield(.resize(rows: 50, cols: 120))
        feed.yield(.eof)
        feed.finish()

        let exit = try await withServer(service: service) { path in
            try await ControlPlaneClient.exec(
                socketPath: path, service: "web", argv: ["sh"],
                tty: true, rows: 24, cols: 80, clientArgv: "podium exec -it web sh",
                input: input, onOutput: { _ in })
        }
        XCTAssertEqual(exit, 0)
        let session = try XCTUnwrap(backend.execLog.last)
        XCTAssertTrue(session.tty)
        let resizes = session.resizes
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes.first?.0, 50)
        XCTAssertEqual(resizes.first?.1, 120)
    }

    func testExecInputEndWithoutEOFReapsSession() async throws {
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.finish()   // killed client: request ends without the explicit EOF frame

        do {
            _ = try await withServer(service: service) { path in
                try await ControlPlaneClient.exec(
                    socketPath: path, service: "web", argv: ["sleep", "300"],
                    tty: true, rows: 24, cols: 80,
                    clientArgv: "podium exec -it web sleep 300",
                    input: input, onOutput: { _ in })
            }
            XCTFail("expected the terminated session to end without an exit frame")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "exec stream ended without an exit code")
        }

        let session = try XCTUnwrap(backend.execLog.last)
        XCTAssertTrue(session.terminated)
        XCTAssertFalse(session.sawEOF)
    }

    func testExecRPCCancellationAfterEOFReapsSession() async throws {
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.yield(.eof)
        feed.finish()   // normal CLI shape: input is done while the command keeps running

        try await withServer(service: service) { path in
            let call = Task {
                try await ControlPlaneClient.exec(
                    socketPath: path, service: "web", argv: ["sleep", "300"],
                    tty: false, rows: 0, cols: 0,
                    clientArgv: "podium exec web sleep 300",
                    input: input, onOutput: { _ in })
            }

            for _ in 0..<100 where backend.execLog.last == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let session = try XCTUnwrap(backend.execLog.last)
            call.cancel()
            _ = try? await call.value

            for _ in 0..<100 where !session.didTerminate {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(session.didTerminate,
                          "transport cancellation must reap a quiet command after stdin EOF")
        }
    }

    func testExecNotRunningCarriesLegacyText() async throws {
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.finish()
        do {
            let exit = try await withServer(service: stubService()) { path in
                try await ControlPlaneClient.exec(
                    socketPath: path, service: "ghost", argv: ["sh"],
                    tty: false, rows: 0, cols: 0, clientArgv: "podium exec ghost sh",
                    input: input, onOutput: { _ in })
            }
            XCTFail("expected .daemon, got exit \(exit)")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "not running")
        }
    }

    func testExecStartupFailureCarriesRuntimeError() async throws {
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.finish()
        do {
            _ = try await withServer(service: stubService(failExec: true)) { path in
                try await ControlPlaneClient.exec(
                    socketPath: path, service: "web", argv: ["sh"],
                    tty: false, rows: 0, cols: 0, clientArgv: "podium exec web sh",
                    input: input, onOutput: { _ in })
            }
            XCTFail("expected .daemon")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "exec startup is broken")
        }
    }

    func testExecEmptyArgvIsRejected() async throws {
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.finish()
        do {
            _ = try await withServer(service: stubService()) { path in
                try await ControlPlaneClient.exec(
                    socketPath: path, service: "web", argv: [],
                    tty: false, rows: 0, cols: 0, clientArgv: "podium exec web",
                    input: input, onOutput: { _ in })
            }
            XCTFail("expected .daemon")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "exec needs svc and args")
        }
    }

    // MARK: streaming cp

    func testCopyInStagesBytesAndReportsCount() async throws {
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let parts = [Data("hello ".utf8), Data("world".utf8)]
        let feeder = ChunkFeeder(parts)

        let written = try await withServer(service: service) { path in
            try await ControlPlaneClient.copyIn(
                socketPath: path, service: "web", path: "/etc/motd", mode: 0o600,
                clientArgv: "podium cp motd web:/etc/motd", nextChunk: { feeder.next() })
        }
        XCTAssertEqual(written, 11, "bytes_written = total streamed in")
        // The staged bytes reached the runtime seam intact (spooled via temp file).
        let imp = try XCTUnwrap(backend.copyLog.lastImport)
        XCTAssertEqual(imp.containerPath, "/etc/motd")
        XCTAssertEqual(imp.mode, 0o600, "mode carried through the meta frame")
        XCTAssertEqual(imp.data, Data("hello world".utf8), "chunk boundaries reassembled byte-exact")
        XCTAssertEqual(backend.auditLog.all.map(\.action), [.copyIn])
        XCTAssertEqual(backend.auditLog.all.first?.argv, "podium cp motd web:/etc/motd")
    }

    func testCopyInUnknownServiceCarriesLegacyText() async throws {
        do {
            _ = try await withServer(service: stubService()) { path in
                try await ControlPlaneClient.copyIn(
                    socketPath: path, service: "ghost", path: "/x", mode: 0,
                    clientArgv: "podium cp f ghost:/x", nextChunk: { nil })
            }
            XCTFail("expected .daemon")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "not running")
        }
    }

    /// Pull-based chunk source for copyIn tests.
    final class ChunkFeeder: @unchecked Sendable {
        private let lock = NSLock(); private var parts: [Data]; private var i = 0
        init(_ parts: [Data]) { self.parts = parts }
        func next() -> Data? { lock.lock(); defer { lock.unlock() }
            guard i < parts.count else { return nil }; defer { i += 1 }; return parts[i] }
    }

    func testCopyOutStreamsFileBytes() async throws {
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        let sink = ByteSink()
        try await withServer(service: service) { path in
            try await ControlPlaneClient.copyOut(
                socketPath: path, service: "web", path: "/etc/motd",
                onChunk: { sink.append($0) })
        }
        XCTAssertEqual(sink.data, StubBackend.exportFixture,
                       "the exported file bytes stream through byte-exact")
        XCTAssertEqual(backend.copyLog.exports.last, "/etc/motd")
    }

    final class ByteSink: @unchecked Sendable {
        private let lock = NSLock(); private var buf = Data()
        func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
    }

    func testCopyOutUnknownServiceCarriesLegacyText() async throws {
        do {
            try await withServer(service: stubService()) { path in
                try await ControlPlaneClient.copyOut(
                    socketPath: path, service: "ghost", path: "/x", onChunk: { _ in })
            }
            XCTFail("expected .daemon")
        } catch let e as ControlPlaneClientError {
            XCTAssertEqual("\(e)", "not running")
        }
    }

    // MARK: logs

    func testLogsTailOverTheSocket() async throws {
        let backend = StubBackend()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logPath = dir.appendingPathComponent("web.log").path
        try Data((1...500).map { "line \($0)" }.joined(separator: "\n").appending("\n").utf8)
            .write(to: URL(fileURLWithPath: logPath))
        backend.logBase.set(logPath)
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)

        let text = try await withServer(service: service) { path in
            var out = Data()
            for try await chunk in ControlPlaneClient.logsStream(
                socketPath: path, service: "web", tail: 2, sinceUsec: 0,
                follow: false, previous: false) {
                out.append(chunk)
            }
            return String(decoding: out, as: UTF8.self)
        }
        XCTAssertEqual(text, "line 499\nline 500\n")
    }

    func testLogsErrorsCarryLegacyTexts() async throws {
        let backend = StubBackend()   // logBase unset → nonexistent paths
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend)
        try await withServer(service: service) { path in
            do {
                for try await _ in ControlPlaneClient.logsStream(
                    socketPath: path, service: "ghost", tail: 0, sinceUsec: 0,
                    follow: false, previous: false) {}
                XCTFail("expected unknown service")
            } catch let e as ControlPlaneClientError {
                XCTAssertEqual("\(e)", "unknown service")
            }
            do {
                for try await _ in ControlPlaneClient.logsStream(
                    socketPath: path, service: "web", tail: 0, sinceUsec: 0,
                    follow: false, previous: true) {}
                XCTFail("expected no previous run")
            } catch let e as ControlPlaneClientError {
                XCTAssertEqual("\(e)", "no previous run for 'web'")
            }
        }
    }

    // MARK: down

    func testDownSchedulesVolumeDeletionThroughTheHook() async throws {
        final class Hook: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls: [Bool] = []
            func record(_ v: Bool) { lock.lock(); calls.append(v); lock.unlock() }
        }
        let hook = Hook()
        let backend = StubBackend()
        let service = PodiumControlService(
            daemonVersion: "client-test-1", stackName: "sockstack", backend: backend,
            onDown: { deleteVolumes in
                hook.record(deleteVolumes)
                return deleteVolumes ? ["/stub/volumes"] : []
            })
        let (plain, withVolumes) = try await withServer(service: service) { path in
            let plain = try await ControlPlaneClient.down(
                socketPath: path, deleteVolumes: false, argv: "podium down")
            let withVolumes = try await ControlPlaneClient.down(
                socketPath: path, deleteVolumes: true, argv: "podium down --volumes -y")
            return (plain, withVolumes)
        }
        XCTAssertTrue(plain.ok)
        XCTAssertEqual(plain.deletedVolumes, [])
        XCTAssertTrue(withVolumes.ok)
        XCTAssertEqual(withVolumes.deletedVolumes, ["/stub/volumes"])
        XCTAssertEqual(hook.calls, [false, true])
        XCTAssertEqual(backend.auditLog.all.map(\.action), [.down, .down])
        XCTAssertEqual(backend.auditLog.all.map(\.argv), ["podium down", "podium down --volumes -y"])
        XCTAssertTrue(backend.auditLog.all.allSatisfy { !$0.user.isEmpty })
    }

    func testDownWithoutLifecycleWiringIsUnimplemented() async throws {
        do {
            let r = try await withServer(service: stubService()) { path in
                try await ControlPlaneClient.down(socketPath: path, deleteVolumes: false, argv: "podium down")
            }
            XCTFail("expected .daemon, got \(r)")
        } catch let e as ControlPlaneClientError {
            XCTAssertTrue("\(e)".contains("not served by this daemon yet"),
                          "unexpected error text: \(e)")
        }
    }

    // MARK: version gate

    func testProtocolMismatchIsRefused() async throws {
        do {
            let r = try await withServer(service: stubService(protocolVersion: 99)) { path in
                try await ControlPlaneClient.listServices(socketPath: path)
            }
            XCTFail("expected .protocolMismatch, got \(r)")
        } catch let e as ControlPlaneClientError {
            guard case .protocolMismatch(let daemon, let client) = e else {
                return XCTFail("expected .protocolMismatch, got \(e)")
            }
            XCTAssertEqual(daemon, 99)
            XCTAssertEqual(client, PodiumRPCVersion.protocolVersion)
        }
    }

    func testBareGetInfoSkipsTheGate() async throws {
        // selftest asserts on the version itself, so getInfo must not refuse.
        let info = try await withServer(service: stubService(protocolVersion: 99)) { path in
            try await ControlPlaneClient.getInfo(socketPath: path)
        }
        XCTAssertEqual(info.protocolVersion, 99)
    }
}
