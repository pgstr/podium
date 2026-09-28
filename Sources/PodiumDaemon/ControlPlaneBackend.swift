// ControlPlaneBackend.swift — the daemon-side surface the control plane
// serves. Lives in PodiumDaemon (like Wire.swift) so the protocol
// carries no gRPC dependency: PodiumRPC consumes it, the Reconciler
// implements it, and service tests stub it without constructing a runtime.

import Foundation
import PodiumCore

/// What a control-plane server may ask of the daemon, one method per verb.
public protocol ControlPlaneBackend: Sendable {
    /// `podium ps` — snapshot of every service.
    func snapshot() async -> [ServiceStatus]

    /// `podium describe <svc>` — nil for an unknown service.
    func describe(_ id: String) async -> Reconciler.DescribeResult?

    /// stop/start/restart — false for an unknown service.
    func stop(_ id: String) async -> Bool
    func start(_ id: String) async -> Bool
    func restart(_ id: String) async -> Bool

    /// `podium reload` / `podium diff` (dryRun). Re-reads the stack file
    /// from disk, validates, then classifies (dryRun) or converges (not).
    /// Throws on unreadable/invalid stack files.
    func reloadFromDisk(dryRun: Bool) async throws -> StackDiff

    /// One raw stats sweep — the Stats stream calls this on its
    /// schedule; CPU is cumulative, the client computes %.
    func stats() async -> [Reconciler.StatSample]

    /// `podium metrics` — one low-cardinality Prometheus snapshot.
    func metrics() async -> PodiumMetrics

    /// `podium events` without -f: everything retained with seq > `after`.
    func events(after: Int) async -> [PodiumEvent]

    /// `podium events -f`: backlog then live push, no polling
    /// anywhere. The stream stays open until the consumer cancels.
    func eventStream(after: Int) async -> AsyncStream<PodiumEvent>

    /// `podium exec`: a live streaming session, or nil when the
    /// service isn't running. Runtime startup failures throw so callers can
    /// report the actual cause.
    func execSession(_ id: String, argv: [String], tty: Bool,
                     rows: UInt16, cols: UInt16) async throws -> (any ExecSession)?

    /// `podium logs`: the service's current log file path, or nil
    /// for an unknown service. `.1` beside it is the --previous log.
    func logPath(_ id: String) async -> String?

    /// `podium cp <local> <svc>:<path>`: copy a host file INTO the
    /// container. The runtime's native transfer moves bytes over a dedicated
    /// vsock in bounded chunks — no shell, so quotes/spaces in the path are
    /// safe, and daemon memory stays flat.
    /// `hostPath` is the staged file the control plane already received.
    func importFile(_ id: String, hostPath: String, containerPath: String, mode: UInt32) async -> CopyOutcome

    /// `podium cp <svc>:<path> <local>`: copy a container file OUT to
    /// `hostPath` (a staging file the control plane then streams to the
    /// client). Same shell-free, bounded-chunk native transfer.
    func exportFile(_ id: String, containerPath: String, hostPath: String) async -> CopyOutcome

    /// Durable audit record for every mutating RPC. `serviceID` is
    /// nil for stack-wide operations such as reload/down.
    func recordAudit(action: AuditAction, serviceID: String?, user: String, argv: String) async
}

public extension ControlPlaneBackend {
    func metrics() async -> PodiumMetrics {
        PodiumMetrics(stack: "unknown", daemonUptimeSeconds: 0, services: [])
    }
}

public enum AuditAction: String, Sendable, Equatable {
    case stop, start, restart, reload, down, exec
    case copyIn = "copy-in"
}

/// Result of a cp transfer. `.failed` carries the runtime's message (missing
/// file, permission).
public enum CopyOutcome: Sendable, Equatable {
    case ok
    case notRunning
    case failed(String)
}

extension Reconciler: ControlPlaneBackend {
    /// Load → validate → classify or reload.
    public func reloadFromDisk(dryRun: Bool) async throws -> StackDiff {
        let newStack = try Stack.load(stackPath)
        try newStack.validate()
        guard newStack.name == stack.name else {
            throw StackNameChangeError(current: stack.name, proposed: newStack.name)
        }
        return dryRun ? classify(newStack) : try await reload(newStack: newStack)
    }

    /// `stats()` and `eventStream(after:)` are satisfied by the actor's own
    /// methods; only `getEvents` needs this shim.
    public func events(after: Int) async -> [PodiumEvent] {
        getEvents(after: after)
    }

    public func logPath(_ id: String) async -> String? {
        guard stack.services.contains(where: { $0.id == id }) else { return nil }
        return StackPaths.logPath(for: stack.name, id: id)
    }

    public func recordAudit(
        action: AuditAction, serviceID: String?, user: String, argv: String
    ) async {
        audit(action: action, serviceID: serviceID, user: user, argv: argv)
    }
}
