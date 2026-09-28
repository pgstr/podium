// PodiumControlService.swift — the PodiumControl (podium.v1) gRPC service.
//
// Serves the version handshake, unary verbs, and streams against the injected
// ControlPlaneBackend (the Reconciler in the daemon, a stub in tests) on the
// stack's canonical `podium.sock`.
//
// Error contract keeps CLI output stable: unknown service → NOT_FOUND
// "unknown service" (describe)
// or ControlResponse{ok:false,error:"unknown service"} (control); reload
// failures → INTERNAL with the thrown error's description.

import Foundation
import GRPCCore
import PodiumCore
import PodiumDaemon

/// Control-plane wire protocol version (see podium.proto conventions).
/// Bumps on breaking changes; clients refuse on major mismatch after GetInfo.
public enum PodiumRPCVersion {
    public static let protocolVersion: UInt32 = 2
}

/// Opt-in exec client lease. A nil input frame is a heartbeat; older clients
/// never enable the lease and retain their existing wire behavior.
private actor ExecClientLease {
    private var enabled = false
    private var missedTicks = 0

    func heartbeat() {
        enabled = true
        missedTicks = 0
    }

    func tickExpired() -> Bool {
        guard enabled else { return false }
        missedTicks += 1
        return missedTicks >= 5
    }
}

public struct PodiumControlService: PbPodiumControl.ServiceProtocol {
    /// Reported verbatim in `InfoResponse.daemon_version`; the daemon injects
    /// its build version, tests inject a sentinel.
    private let daemonVersion: String
    private let stackName: String
    private let backend: any ControlPlaneBackend
    /// Overridable so tests can exercise the client's refuse-on-mismatch
    /// gate without forking the process; the daemon never passes it.
    private let protocolVersion: UInt32
    /// Down is daemon lifecycle, not reconciler state — main.swift injects
    /// this: flag the volume deletion for the teardown path, trigger
    /// shutdown, return the volume roots scheduled for deletion (empty when
    /// none exist or deletion wasn't requested). nil = not wired (tests
    /// without lifecycle get UNIMPLEMENTED).
    private let onDown: (@Sendable (_ deleteVolumes: Bool) async -> [String])?

    public init(
        daemonVersion: String, stackName: String, backend: any ControlPlaneBackend,
        protocolVersion: UInt32 = PodiumRPCVersion.protocolVersion,
        onDown: (@Sendable (_ deleteVolumes: Bool) async -> [String])? = nil
    ) {
        self.daemonVersion = daemonVersion
        self.stackName = stackName
        self.backend = backend
        self.protocolVersion = protocolVersion
        self.onDown = onDown
    }

    // MARK: GetInfo

    public func getInfo(
        request: GRPCCore.ServerRequest<PbInfoRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbInfoResponse> {
        var info = PbInfoResponse()
        info.daemonVersion = daemonVersion
        info.protocolVersion = protocolVersion
        info.stackName = stackName
        info.pid = getpid()
        return GRPCCore.ServerResponse(message: info)
    }

    // MARK: Stubs

    /// UNIMPLEMENTED with context, so a client probing a daemon that lacks
    /// an RPC gets an actionable error.
    private func unimplemented(_ rpc: String, story: String) -> GRPCCore.RPCError {
        GRPCCore.RPCError(
            code: .unimplemented,
            message: "PodiumControl.\(rpc) is not served by this daemon yet (lands with \(story))"
        )
    }

    // MARK: Unary verbs

    public func listServices(
        request: GRPCCore.ServerRequest<PbEmpty>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbPsResponse> {
        let services = await backend.snapshot()
        return GRPCCore.ServerResponse(
            message: PbPsResponse(stack: stackName, services: services))
    }

    public func describe(
        request: GRPCCore.ServerRequest<PbServiceRef>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbDescribeResponse> {
        guard let result = await backend.describe(request.message.id) else {
            // Message text is part of the CLI contract ("podium: <message>").
            throw GRPCCore.RPCError(code: .notFound, message: "unknown service")
        }
        return GRPCCore.ServerResponse(message: PbDescribeResponse(result))
    }

    // MARK: Streams

    /// Server-push stats: one raw sweep per interval, framed on the daemon's
    /// schedule — the client renders frames as they arrive and computes CPU%
    /// from cumulative deltas. interval_ms = 0 → 2 s; floored
    /// at 100 ms so a buggy client can't turn statistics() into a busy loop.
    public func stats(
        request: GRPCCore.ServerRequest<PbStatsRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<PbStatsSample> {
        let ms = request.message.intervalMs
        let interval = Duration.milliseconds(Int64(max(100, ms == 0 ? 2000 : ms)))
        let backend = self.backend
        return GRPCCore.StreamingServerResponse { writer in
            while true {
                try await writer.write(PbStatsSample(await backend.stats()))
                try await Task.sleep(for: interval)   // throws on client cancel
            }
        }
    }

    public func metrics(
        request: GRPCCore.ServerRequest<PbEmpty>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbMetricsResponse> {
        GRPCCore.ServerResponse(message: PbMetricsResponse(await backend.metrics()))
    }

    public func control(
        request: GRPCCore.ServerRequest<PbControlRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbControlResponse> {
        let id = request.message.service.id
        let ok: Bool
        switch request.message.action {
        case .stop:
            await backend.recordAudit(action: .stop, serviceID: id,
                                      user: request.message.client.user,
                                      argv: request.message.client.argv)
            ok = await backend.stop(id)
        case .start:
            await backend.recordAudit(action: .start, serviceID: id,
                                      user: request.message.client.user,
                                      argv: request.message.client.argv)
            ok = await backend.start(id)
        case .restart:
            await backend.recordAudit(action: .restart, serviceID: id,
                                      user: request.message.client.user,
                                      argv: request.message.client.argv)
            ok = await backend.restart(id)
        case .unspecified, .UNRECOGNIZED:
            throw GRPCCore.RPCError(code: .invalidArgument, message: "unspecified control action")
        }
        var response = PbControlResponse()
        response.ok = ok
        if !ok { response.error = "unknown service" }
        return GRPCCore.ServerResponse(message: response)
    }

    public func reload(
        request: GRPCCore.ServerRequest<PbReloadRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbReloadResponse> {
        do {
            if !request.message.dryRun {
                await backend.recordAudit(
                    action: .reload, serviceID: nil,
                    user: request.message.client.user,
                    argv: request.message.client.argv)
            }
            let diff = try await backend.reloadFromDisk(dryRun: request.message.dryRun)
            return GRPCCore.ServerResponse(message: PbReloadResponse(diff))
        } catch let error as GRPCCore.RPCError {
            throw error
        } catch {
            throw GRPCCore.RPCError(code: .internalError, message: "\(error)")
        }
    }

    /// Down: ack + the volume roots the daemon will delete during
    /// teardown, after every container stopped. The response reports what is
    /// *scheduled*; the CLI verifies the path is gone once the lock releases.
    public func down(
        request: GRPCCore.ServerRequest<PbDownRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbDownResponse> {
        guard let onDown else {
            throw unimplemented("Down", story: "daemon lifecycle wiring")
        }
        await backend.recordAudit(
            action: .down, serviceID: nil,
            user: request.message.client.user,
            argv: request.message.client.argv)
        var resp = PbDownResponse()
        resp.deletedVolumes = await onDown(request.message.deleteVolumes)
        resp.ok = true
        return GRPCCore.ServerResponse(message: resp)
    }

    /// Logs: bounded-window reads through LogReader — tail is O(tail)
    /// backward scan, since is a forward line filter, follow polls the file
    /// daemon-side (rotation-aware). Bytes go out as ≤64 KiB chunks with
    /// timestamp prefixes intact; the CLI writes them verbatim.
    public func logs(
        request: GRPCCore.ServerRequest<PbLogsRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<PbLogChunk> {
        let m = request.message
        let backend = self.backend
        return GRPCCore.StreamingServerResponse { writer in
            guard let base = await backend.logPath(m.service.id) else {
                throw GRPCCore.RPCError(code: .notFound, message: "unknown service")
            }
            let path = m.previous ? base + ".1" : base
            guard FileManager.default.fileExists(atPath: path) else {
                throw GRPCCore.RPCError(
                    code: .notFound,
                    message: m.previous
                        ? "no previous run for '\(m.service.id)'"
                        : "no logs for '\(m.service.id)'")
            }
            let cutoff = m.sinceUsec > 0
                ? Date(timeIntervalSince1970: Double(m.sinceUsec) / 1_000_000) : nil
            for try await chunk in LogReader.stream(
                path: path, tail: Int(m.tail), sinceCutoff: cutoff, follow: m.follow) {
                var c = PbLogChunk()
                c.data = chunk
                try await writer.write(c)
            }
            return [:]
        }
    }

    /// Events: backlog with seq > after_seq; with follow, stays open and
    /// pushes each event as the reconciler persists it (no polling).
    public func events(
        request: GRPCCore.ServerRequest<PbEventsRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<PbEvent> {
        let after = Int(request.message.afterSeq)
        let follow = request.message.follow
        let backend = self.backend
        return GRPCCore.StreamingServerResponse { writer in
            if follow {
                for await e in await backend.eventStream(after: after) {
                    try await writer.write(PbEvent(e))
                }
            } else {
                for e in await backend.events(after: after) {
                    try await writer.write(PbEvent(e))
                }
            }
            return [:]
        }
    }

    /// Bidi exec. Contract: first inbound message is `start`; then
    /// stdin/resize/stdin_eof in any order. Outbound: stdout/stderr chunks,
    /// then exactly one exit_code. Errors such as `not running` ride the
    /// error field.
    ///
    /// Pump layout: the output pump runs as a child task; the input pump
    /// stays on the producer task (the request iterator can't hop tasks).
    /// A vanished client surfaces as an iterator/writer error → terminate()
    /// kills the process, which finishes the output stream. terminate() is
    /// idempotent and also runs on the clean path (no-op after exit).
    public func exec(
        request: GRPCCore.StreamingServerRequest<PbExecInput>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<PbExecOutput> {
        let backend = self.backend
        return GRPCCore.StreamingServerResponse { writer in
            var iterator = request.messages.makeAsyncIterator()

            func fail(_ text: String) async throws -> GRPCCore.Metadata {
                var out = PbExecOutput()
                out.error = text
                try await writer.write(out)
                return [:]
            }

            guard let first = try await iterator.next(),
                  case .start(let start) = first.input else {
                return try await fail("exec stream must open with start")
            }
            guard !start.service.id.isEmpty, !start.argv.isEmpty else {
                return try await fail("exec needs svc and args")
            }
            await backend.recordAudit(
                action: .exec, serviceID: start.service.id,
                user: start.client.user, argv: start.client.argv)
            let session: any ExecSession
            do {
                guard let started = try await backend.execSession(
                    start.service.id, argv: start.argv, tty: start.tty,
                    rows: UInt16(clamping: start.rows), cols: UInt16(clamping: start.cols)
                ) else {
                    return try await fail("not running")
                }
                session = started
            } catch {
                return try await fail("\(error)")
            }
            let lease = ExecClientLease()

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await chunk in session.output {
                            var out = PbExecOutput()
                            switch chunk {
                            case .stdout(let d):   out.stdout = d
                            case .stderr(let d):   out.stderr = d
                            case .exit(let code):  out.exitCode = code
                            }
                            try await writer.write(out)
                            if case .exit = chunk { break }
                        }
                    }
                    // A non-interactive client normally sends stdin_eof and
                    // finishes its request stream immediately, long before a
                    // quiet command exits. If that client is killed afterward,
                    // neither the exhausted request iterator nor the silent
                    // output stream observes it. The transport cancellation
                    // handle is the one reliable disconnect signal.
                    let cancellation = context.cancellation
                    group.addTask {
                        do {
                            try await cancellation.cancelled
                            if !Task.isCancelled { await session.terminate() }
                        } catch {
                            // Normal group teardown cancels this waiter after
                            // the process exits; there is nothing left to reap.
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(1)) }
                            catch { return }
                            if await lease.tickExpired() {
                                print("[exec] \(start.service.id): client lease expired — terminating process")
                                await session.terminate()
                                cancellation.cancel()
                                return
                            }
                        }
                    }
                    // Input pump. An explicit stdin_eof is an intentional
                    // half-close; otherwise the stream ending means the client
                    // vanished and the container process must be reaped.
                    var sawStdinEOF = false
                    do {
                        while let msg = try await iterator.next() {
                            switch msg.input {
                            case .stdin(let d):
                                await session.writeStdin(d)
                            case .resize(let r):
                                await session.resize(rows: UInt16(clamping: r.rows),
                                                     cols: UInt16(clamping: r.cols))
                            case .stdinEof:
                                sawStdinEOF = true
                                await session.stdinEOF()
                            case nil:
                                await lease.heartbeat()
                            case .start:
                                break   // duplicate start — ignore
                            }
                        }
                        // Every intentional client half-close carries the
                        // explicit stdin_eof frame. A stream that disappears
                        // without it is an abruptly killed CLI, even when the
                        // transport reports a clean end instead of throwing.
                        if !sawStdinEOF { await session.terminate() }
                    } catch {
                        await session.terminate()   // client vanished mid-session
                    }
                    try await group.next()          // output pump: exit or teardown
                    group.cancelAll()
                }
            } catch {
                await session.terminate()           // writer failed — don't leak the process
                throw error
            }
            await session.terminate()               // idempotent; no-op after exit
            return [:]
        }
    }

    /// CopyIn. Contract: first inbound message carries `meta` (service
    /// + path + mode); the rest carry `data`. We stage the bytes into a host
    /// temp file, then hand it to the runtime's native transfer — no shell,
    /// no exec. `bytes_written` is the count we staged.
    public func copyIn(
        request: GRPCCore.StreamingServerRequest<PbFileChunk>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<PbCopyResponse> {
        func done(ok: Bool, bytes: UInt64 = 0, error: String = "") -> GRPCCore.ServerResponse<PbCopyResponse> {
            var r = PbCopyResponse()
            r.ok = ok; r.bytesWritten = bytes; r.error = error
            return GRPCCore.ServerResponse(message: r)
        }
        var iterator = request.messages.makeAsyncIterator()
        guard let first = try await iterator.next(), case .meta(let meta) = first.chunk else {
            return done(ok: false, error: "copy stream must open with meta")
        }
        guard !meta.service.id.isEmpty, !meta.containerPath.isEmpty else {
            return done(ok: false, error: "copy needs service and path")
        }
        await backend.recordAudit(
            action: .copyIn, serviceID: meta.service.id,
            user: meta.client.user, argv: meta.client.argv)

        let staging = Self.stagingPath()
        defer { try? FileManager.default.removeItem(atPath: staging) }
        FileManager.default.createFile(atPath: staging, contents: nil)
        var total: UInt64 = 0
        do {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: staging))
            defer { try? fh.close() }
            while let msg = try await iterator.next() {
                if case .data(let d) = msg.chunk {
                    try fh.write(contentsOf: d)      // spooled to disk → flat memory
                    total += UInt64(d.count)
                }
            }
            try fh.close()
        } catch {
            return done(ok: false, bytes: total, error: "staging failed: \(error)")
        }

        let mode: UInt32 = meta.mode == 0 ? 0o644 : meta.mode
        switch await backend.importFile(meta.service.id, hostPath: staging,
                                        containerPath: meta.containerPath, mode: mode) {
        case .ok:          return done(ok: true, bytes: total)
        case .notRunning:  return done(ok: false, bytes: total, error: "not running")
        case .failed(let m): return done(ok: false, bytes: total, error: m)
        }
    }

    /// CopyOut. The runtime exports the container file to a host temp
    /// file (native transfer); we stream that out as `FileChunk.data` in
    /// bounded chunks. A missing file / not-running surfaces as an RPC error
    /// the client prints after `podium: `.
    public func copyOut(
        request: GRPCCore.ServerRequest<PbCopyRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<PbFileChunk> {
        let req = request.message
        guard !req.service.id.isEmpty, !req.containerPath.isEmpty else {
            throw GRPCCore.RPCError(code: .invalidArgument, message: "copy needs service and path")
        }
        let backend = self.backend
        return GRPCCore.StreamingServerResponse { writer in
            let staging = Self.stagingPath()
            defer { try? FileManager.default.removeItem(atPath: staging) }
            switch await backend.exportFile(req.service.id, containerPath: req.containerPath, hostPath: staging) {
            case .notRunning:
                throw GRPCCore.RPCError(code: .notFound, message: "not running")
            case .failed(let m):
                throw GRPCCore.RPCError(code: .failedPrecondition, message: m)
            case .ok:
                let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: staging))
                defer { try? fh.close() }
                while let d = try fh.read(upToCount: 64 * 1024), !d.isEmpty {
                    var fc = PbFileChunk(); fc.data = d
                    try await writer.write(fc)
                }
                return [:]
            }
        }
    }

    /// A unique host path in the daemon's temp dir for staging one cp side.
    private static func stagingPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-cp-\(UUID().uuidString)").path
    }
}
