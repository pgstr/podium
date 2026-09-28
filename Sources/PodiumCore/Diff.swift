// Diff.swift — pure stack-diff classification, so `podium diff`/`reload`
// semantics are unit-testable without a runtime.
import Foundation

/// Result of diffing a new stack spec against the currently-running one.
/// Wire-compatible with the control protocol's reload/diff responses.
public struct StackDiff: Codable, Sendable, Equatable {
    public let started: [String]     // in new, not in old
    public let stopped: [String]     // in old, not in new
    public let restarted: [String]   // in both, spec changed
    public let unchanged: [String]   // in both, spec identical

    public init(started: [String], stopped: [String], restarted: [String], unchanged: [String]) {
        self.started = started; self.stopped = stopped
        self.restarted = restarted; self.unchanged = unchanged
    }
}

/// Classify `new` against `old`. Pure; preserves each list's declaration order
/// (old order for `stopped`, new order for the rest).
public func classifyStackDiff(old: Stack, new: Stack) -> StackDiff {
    let oldIds   = old.services.map { $0.id }
    let newIdSet = Set(new.services.map { $0.id })
    let oldById  = Dictionary(uniqueKeysWithValues: old.services.map { ($0.id, $0) })

    let stopped   = oldIds.filter { !newIdSet.contains($0) }
    let restarted = new.services.filter { svc in
        guard let oldSvc = oldById[svc.id] else { return false }
        return oldSvc != svc
    }.map { $0.id }
    let started   = new.services.map { $0.id }.filter { oldById[$0] == nil }
    let unchanged = new.services.map { $0.id }
        .filter { !restarted.contains($0) && !started.contains($0) }
    return StackDiff(started: started, stopped: stopped, restarted: restarted, unchanged: unchanged)
}
