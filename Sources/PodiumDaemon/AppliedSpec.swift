// AppliedSpec.swift — the persisted desired spec.
//
// `spec.applied.json` records the resolved stack that is actually running —
// post-compose translation, post-defaults. It is written whenever a spec is
// committed (bring-up, reload) and read at boot to detect drift between the
// stack file on disk and what the previous daemon incarnation was running.
// It lives next to the state/ directory: ~/.podium/<stack>/spec.applied.json
// in production (the URL is derived from the StateStore's directory so tests
// stay hermetic).
//
// An explicit `podium apply <file>` proceeds with the FILE and re-commits it;
// the applied spec is used to WARN about drift, not to override user intent.

import Foundation
import PodiumCore

public enum AppliedSpec {
    /// `spec.applied.json` next to the given state directory.
    public static func url(stateDirectory: URL) -> URL {
        stateDirectory.deletingLastPathComponent()
            .appendingPathComponent("spec.applied.json")
    }

    /// Atomic write (tmp → rename), same crash contract as the state store.
    public static func save(_ stack: Stack, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(stack)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [])
        if rename(tmp.path, url.path) != 0 {
            throw StateStoreError.io("spec.applied.json rename: errno \(errno)")
        }
    }

    /// Last committed spec, or nil if none was ever written.
    public static func load(from url: URL) -> Stack? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stack.self, from: data)
    }
}
