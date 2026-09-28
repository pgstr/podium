// ControlPlaneServer.swift — gRPC on the stack's canonical `podium.sock`.
//
// The daemon owns the listening socket: created here with mode 0600 *before*
// listen(), then handed to the NIO transport (which takes ownership of the
// fd). Every accepted connection passes a peer-uid gate — the transport's
// per-connection accept callback reads LOCAL_PEERCRED (SO_PEERCRED on Linux)
// off the accepted channel and closes it unless the peer uid matches the
// daemon's. See PeerCredentials for the fd-based variant of the check.
//
// ControlPlaneClient is the dialing side used by the CLI and selftest.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOCore
import PodiumCore
import PodiumDaemon

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ControlPlaneError: Error, CustomStringConvertible {
    case socketFailed(String)
    case pathTooLong(String)
    case peerRejected(peer: uid_t, expected: uid_t)
    case unidentifiablePeer

    public var description: String {
        switch self {
        case .socketFailed(let what):
            return "control plane v2 socket failed: \(what)"
        case .pathTooLong(let path):
            return "control plane v2 socket path exceeds sun_path: \(path)"
        case .peerRejected(let peer, let expected):
            return "control plane v2: rejected connection from uid \(peer) (daemon runs as uid \(expected))"
        case .unidentifiablePeer:
            return "control plane v2: rejected connection with unreadable peer credentials"
        }
    }
}

public enum ControlPlaneServer {

    /// Serves `service` on an AF_UNIX gRPC socket at `socketPath` until the
    /// surrounding task is cancelled. Replaces a stale socket file; refuses
    /// connections from any uid other than `expectedPeerUID`.
    ///
    /// - Parameters:
    ///   - socketPath: Filesystem path, `StackPaths.socketPath` in the daemon.
    ///   - service: Normally `PodiumControlService`.
    ///   - expectedPeerUID: Defaults to the daemon's own uid. Overridable so
    ///     tests can exercise the rejection path without a second user.
    ///   - onListening: Invoked once the socket is accepting connections.
    public static func serve(
        socketPath: String,
        service: some GRPCCore.RegistrableRPCService,
        expectedPeerUID: uid_t = getuid(),
        onListening: (@Sendable () -> Void)? = nil
    ) async throws {
        let fd = try makeListeningSocket(at: socketPath)
        defer { unlink(socketPath) }

        var config = HTTP2ServerTransport.Posix.Config.defaults
        config.channelDebuggingCallbacks.onAcceptTCPConnection = { channel in
            enforcePeerUID(on: channel, expected: expectedPeerUID)
        }
        // The transport takes ownership of fd — no close() on our side.
        let transport = HTTP2ServerTransport.Posix(
            listeningSocketDescriptor: Int(fd),
            transportSecurity: .plaintext,
            config: config
        )
        try await withGRPCServer(transport: transport, services: [service]) { _ in
            onListening?()
            // Serve until cancelled (daemon shutdown).
            while true {
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// socket → bind → chmod 0600 → listen. The chmod lands before listen(),
    /// so no connection is ever accepted through a wider mode; the parent
    /// stack dir (0700) covers the bind-to-chmod window against non-owners.
    private static func makeListeningSocket(at path: String) throws -> Int32 {
        // A stale socket from a crashed daemon would fail bind with EADDRINUSE.
        // The instance lock guarantees no *live* daemon holds it.
        unlink(path)

        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else {
            throw ControlPlaneError.socketFailed("socket(): \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            close(fd)
            throw ControlPlaneError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            path.withCString { cPath in
                _ = strncpy(UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self), cPath, maxLen)
            }
        }
        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ControlPlaneError.socketFailed("bind(\(path)): \(String(cString: strerror(err)))")
        }
        guard chmod(path, 0o600) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ControlPlaneError.socketFailed("chmod(\(path)): \(String(cString: strerror(err)))")
        }
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ControlPlaneError.socketFailed("listen(\(path)): \(String(cString: strerror(err)))")
        }
        return fd
    }

    /// Per-connection gate, run on the accepted channel before any HTTP/2
    /// processing: read the kernel-verified peer uid, close on mismatch.
    /// Fails closed — a channel whose credentials cannot be read is dropped.
    private static func enforcePeerUID(
        on channel: any Channel,
        expected: uid_t
    ) -> EventLoopFuture<Void> {
        guard let provider = channel as? any SocketOptionProvider else {
            return channel.close().flatMap {
                channel.eventLoop.makeFailedFuture(ControlPlaneError.unidentifiablePeer)
            }
        }

        #if canImport(Glibc)
        let peerUID: EventLoopFuture<uid_t> = provider.unsafeGetSocketOption(
            level: SocketOptionLevel(SOL_SOCKET),
            name: SocketOptionName(SO_PEERCRED)
        ).map { (cred: LinuxUcred) in cred.uid }
        #else
        // LOCAL_PEERCRED (level SOL_LOCAL) yields an xucred; cr_uid is the
        // effective uid the peer held at connect() time.
        let peerUID: EventLoopFuture<uid_t> = provider.unsafeGetSocketOption(
            level: SocketOptionLevel(SOL_LOCAL),
            name: SocketOptionName(LOCAL_PEERCRED)
        ).map { (cred: xucred) in cred.cr_uid }
        #endif

        return peerUID.flatMap { uid in
            if uid == expected {
                return channel.eventLoop.makeSucceededFuture(())
            }
            return channel.close().flatMap {
                channel.eventLoop.makeFailedFuture(
                    ControlPlaneError.peerRejected(peer: uid, expected: expected))
            }
        }.flatMapError { error in
            // Credential read failed → fail closed.
            channel.close().flatMap {
                channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
}

/// Errors the CLI shows the user verbatim (`podium: <description>`).
public enum ControlPlaneClientError: Error, Sendable, CustomStringConvertible {
    /// GetInfo handshake found an incompatible daemon (proto conventions:
    /// refuse on major mismatch — the version is a single major today).
    case protocolMismatch(daemon: UInt32, client: UInt32)
    /// The daemon answered with a typed error (NOT_FOUND, INTERNAL, …).
    case daemon(String)

    public var description: String {
        switch self {
        case .protocolMismatch(let d, let c):
            return "daemon speaks control-plane protocol v\(d), this CLI speaks v\(c) — upgrade the older side"
        case .daemon(let message):
            return message
        }
    }
}

public enum ControlPlaneClient {
    /// Dials the socket and performs the bare GetInfo handshake (no
    /// version gate — selftest asserts on the returned version itself).
    public static func getInfo(socketPath: String) async throws -> PbInfoResponse {
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
        ) { client in
            try await PbPodiumControl.Client(wrapping: client).getInfo(PbInfoRequest())
        }
    }

    // MARK: unary verbs

    /// `podium ps`.
    public static func listServices(
        socketPath: String
    ) async throws -> (stack: String, services: [PodiumDaemon.ServiceStatus]) {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            let resp = try await client.listServices(PbEmpty())
            return (resp.stack, resp.services.map(\.wire))
        }
    }

    /// `podium metrics` — unary snapshot rendered by the CLI as Prometheus text.
    public static func metrics(socketPath: String) async throws -> PodiumMetrics {
        try await withVerifiedClient(socketPath: socketPath) { client, info in
            try await client.metrics(PbEmpty()).wire(stack: info.stackName)
        }
    }

    /// `podium describe <svc>`. The stack name rides the GetInfo handshake —
    /// DescribeResponse doesn't carry it (the daemon serves exactly one stack).
    public static func describe(
        socketPath: String, id: String
    ) async throws -> Reconciler.DescribeResult {
        try await withVerifiedClient(socketPath: socketPath) { client, info in
            var ref = PbServiceRef()
            ref.id = id
            let resp = try await client.describe(ref)
            return resp.wire(stack: info.stackName)
        }
    }

    /// stop / start / restart.
    public static func control(
        socketPath: String, action: PbControlRequest.Action, id: String, argv: String
    ) async throws -> PbControlResponse {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            var req = PbControlRequest()
            req.service.id = id
            req.action = action
            req.client = clientInfo(argv: argv)
            return try await client.control(req)
        }
    }

    /// `podium reload` (dryRun: false) and `podium diff` (dryRun: true).
    public static func reload(
        socketPath: String, dryRun: Bool, argv: String
    ) async throws -> StackDiff {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            var req = PbReloadRequest()
            req.dryRun = dryRun
            req.client = clientInfo(argv: argv)
            return try await client.reload(req).wire
        }
    }

    /// `podium down [--volumes]`. The response carries the volume
    /// roots the daemon *scheduled* for deletion — actual removal happens
    /// during teardown, after every container stopped; the CLI verifies
    /// the path is gone once the instance lock releases.
    public static func down(
        socketPath: String, deleteVolumes: Bool, argv: String
    ) async throws -> PbDownResponse {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            var req = PbDownRequest()
            req.deleteVolumes = deleteVolumes
            req.client = clientInfo(argv: argv)
            return try await client.down(req)
        }
    }

    // MARK: server streams

    /// One `podium top` frame: the stack name (from the handshake) plus a
    /// full stats sweep, pushed on the daemon's schedule.
    public struct StatsFrame: Sendable {
        public let stack: String
        public let samples: [Reconciler.StatSample]
    }

    /// `podium top`: frames arrive on the daemon's schedule — the CLI just
    /// iterates. Ending the iteration cancels the call; a dropped daemon
    /// surfaces as a thrown error. A stream rather than a callback so the
    /// main-actor CLI can consume it without Sendable gymnastics.
    public static func statsStream(
        socketPath: String, intervalMs: UInt32
    ) -> AsyncThrowingStream<StatsFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: StatsFrame.self)
        let task = Task {
            do {
                try await withVerifiedClient(socketPath: socketPath) { client, info in
                    var req = PbStatsRequest()
                    req.intervalMs = intervalMs
                    try await client.stats(req) { resp in
                        for try await frame in resp.messages {
                            continuation.yield(StatsFrame(stack: info.stackName, samples: frame.wireSamples))
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// `podium events [-f]`: backlog then (with follow) live push — the
    /// stream stays open until the consumer stops iterating or the process
    /// exits.
    public static func eventsStream(
        socketPath: String, after: Int, follow: Bool
    ) -> AsyncThrowingStream<PodiumEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PodiumEvent.self)
        let task = Task {
            do {
                try await withVerifiedClient(socketPath: socketPath) { client, _ in
                    var req = PbEventsRequest()
                    req.afterSeq = Int64(after)
                    req.follow = follow
                    try await client.events(req) { resp in
                        for try await e in resp.messages { continuation.yield(e.wire) }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// `podium logs`: raw log bytes, tail/since/follow/previous
    /// server-side. Ending iteration cancels the call (follow teardown).
    public static func logsStream(
        socketPath: String, service: String,
        tail: Int32, sinceUsec: Int64, follow: Bool, previous: Bool
    ) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let task = Task {
            do {
                try await withVerifiedClient(socketPath: socketPath) { client, _ in
                    var req = PbLogsRequest()
                    req.service.id = service
                    req.tail = tail
                    req.sinceUsec = sinceUsec
                    req.follow = follow
                    req.previous = previous
                    try await client.logs(req) { resp in
                        for try await chunk in resp.messages { continuation.yield(chunk.data) }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: bidi exec

    /// Client-side input for one exec session.
    public enum ExecInput: Sendable {
        case stdin(Data)
        case resize(rows: UInt16, cols: UInt16)
        case eof
    }

    /// Client-side output chunk (exit code is the return value instead).
    public enum ExecOutput: Sendable {
        case stdout(Data)
        case stderr(Data)
    }

    /// Drives one exec end-to-end and returns the process exit code.
    ///
    /// `input` is pumped to the daemon until it finishes (or the RPC ends —
    /// whichever is first; ending the RPC cancels the pump). `onOutput` is
    /// called from the RPC's task as chunks arrive — pass something
    /// thread-safe like raw FD writes; do not touch actor state in it.
    /// Daemon-reported failures ("not running", bad start) throw
    /// `ControlPlaneClientError.daemon`.
    public static func exec(
        socketPath: String, service: String, argv: [String],
        tty: Bool, rows: UInt16, cols: UInt16, clientArgv: String,
        input: AsyncStream<ExecInput>,
        onOutput: @escaping @Sendable (ExecOutput) -> Void
    ) async throws -> Int32 {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            try await client.exec { writer in
                var start = PbExecInput.Start()
                start.service.id = service
                start.argv = argv
                start.tty = tty
                start.rows = UInt32(rows)
                start.cols = UInt32(cols)
                start.client = clientInfo(argv: clientArgv)
                var first = PbExecInput()
                first.input = .start(start)
                try await writer.write(first)
                var sentEOF = false
                for await inp in input {
                    var msg = PbExecInput()
                    switch inp {
                    case .stdin(let d):
                        msg.input = .stdin(d)
                    case .resize(let r, let c):
                        var resize = PbExecInput.Resize()
                        resize.rows = UInt32(r)
                        resize.cols = UInt32(c)
                        msg.input = .resize(resize)
                    case .eof:
                        sentEOF = true
                        msg.input = .stdinEof(true)
                    }
                    try await writer.write(msg)
                }
                // stdin_eof is only a half-close. Keep the RPC request side
                // open until the response handler sees the process exit; that
                // way killing a quiet client closes an *active* stream and the
                // daemon can reap its guest process immediately. Returning
                // without EOF remains the explicit abrupt-input path.
                if sentEOF {
                    while true {
                        let heartbeat = PbExecInput() // nil oneof = compatible lease frame
                        try await writer.write(heartbeat)
                        try await Task.sleep(for: .seconds(1))
                    }
                }
            } onResponse: { resp in
                for try await out in resp.messages {
                    switch out.output {
                    case .stdout(let d):    onOutput(.stdout(d))
                    case .stderr(let d):    onOutput(.stderr(d))
                    case .exitCode(let c):  return c
                    case .error(let text):  throw ControlPlaneClientError.daemon(text)
                    case nil:               continue
                    }
                }
                throw ControlPlaneClientError.daemon("exec stream ended without an exit code")
            }
        }
    }

    // MARK: streaming cp

    /// `podium cp <svc>:<path> <local>` — stream a file out of the container.
    /// `onChunk` is called with each byte run as it arrives (write it straight
    /// to the destination fd/file; don't touch actor state). Daemon-reported
    /// failures ("not running", missing file) throw `ControlPlaneClientError.daemon`.
    public static func copyOut(
        socketPath: String, service: String, path: String,
        onChunk: @escaping @Sendable (Data) -> Void
    ) async throws {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            var req = PbCopyRequest()
            req.service.id = service
            req.containerPath = path
            try await client.copyOut(req) { resp in
                for try await fc in resp.messages {
                    if case .data(let d) = fc.chunk { onChunk(d) }
                }
            }
        }
    }

    /// `podium cp <local> <svc>:<path>` — stream a file into the container.
    /// `nextChunk` is pulled for the file's bytes (from a local read or stdin)
    /// and must return nil at EOF; it's called only when the previous chunk
    /// has been handed to the transport, so the client never buffers more than
    /// one chunk (flat memory for a 1 GB file). The meta frame goes first.
    /// Returns the bytes accepted. A failed transfer throws `.daemon`.
    public static func copyIn(
        socketPath: String, service: String, path: String, mode: UInt32,
        clientArgv: String, nextChunk: @escaping @Sendable () -> Data?
    ) async throws -> UInt64 {
        try await withVerifiedClient(socketPath: socketPath) { client, _ in
            try await client.copyIn { writer in
                var meta = PbFileChunk.Meta()
                meta.service.id = service
                meta.containerPath = path
                meta.mode = mode
                meta.client = clientInfo(argv: clientArgv)
                var first = PbFileChunk()
                first.chunk = .meta(meta)
                try await writer.write(first)
                while let d = nextChunk(), !d.isEmpty {
                    var fc = PbFileChunk()
                    fc.chunk = .data(d)
                    try await writer.write(fc)
                }
            } onResponse: { resp in
                let m = try resp.message
                if !m.ok {
                    throw ControlPlaneClientError.daemon(m.error.isEmpty ? "copy failed" : m.error)
                }
                return m.bytesWritten
            }
        }
    }

    // MARK: plumbing

    /// Dials, runs the GetInfo version gate, then `body` on the same
    /// connection. Typed daemon errors surface as `.daemon(message)`;
    /// transport failures (unavailable, refused socket) pass through and the
    /// CLI maps them to its "no daemon at …" message.
    private static func withVerifiedClient<R: Sendable>(
        socketPath: String,
        _ body: @escaping @Sendable (
            PbPodiumControl.Client<HTTP2ClientTransport.Posix>, PbInfoResponse
        ) async throws -> R
    ) async throws -> R {
        do {
            return try await withGRPCClient(
                transport: .http2NIOPosix(
                    target: .unixDomainSocket(path: socketPath),
                    transportSecurity: .plaintext
                )
            ) { raw in
                let client = PbPodiumControl.Client(wrapping: raw)
                let info = try await client.getInfo(PbInfoRequest())
                guard info.protocolVersion == PodiumRPCVersion.protocolVersion else {
                    throw ControlPlaneClientError.protocolMismatch(
                        daemon: info.protocolVersion, client: PodiumRPCVersion.protocolVersion)
                }
                return try await body(client, info)
            }
        } catch let e as RPCError where e.code != .unavailable {
            throw ControlPlaneClientError.daemon(e.message)
        }
    }

    /// Audit metadata on mutating RPCs, written to the event log.
    private static func clientInfo(argv: String) -> PbClientInfo {
        var ci = PbClientInfo()
        ci.user = NSUserName()
        ci.argv = argv
        return ci
    }
}
