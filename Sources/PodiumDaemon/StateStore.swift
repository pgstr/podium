// StateStore.swift — durable state.
//
// Persist-first: every transition is durable before it is acted on. The
// store owns `state/` inside the stack directory:
//
//   state/
//     manifest.json    # schema version + pointer to current snapshot
//     state.json       # atomic snapshot (write tmp → fsync → rename)
//     state.json.tmp   # in-flight snapshot; NEVER read (may be torn)
//     events.jsonl     # append-only event log
//     events.jsonl.1   # previous log generation (size rotation keeps one)
//
// Crash-safety contract (exercised by the 10k-cycle injection test):
// a crash at ANY point inside `save`/`append`/rotation leaves the store
// loadable, yielding the last durably saved snapshot and an event log whose
// only permitted damage is a torn FINAL line (which `loadEvents` drops).
// The tmp file is written, fsync'd, then atomically rename(2)'d over
// state.json — readers see the old complete snapshot or the new complete
// snapshot, never a mixture. JSON + JSONL, not SQLite, by design:
// state is KBs, transitions are low-frequency, `cat` is the debugger.

import Foundation
import PodiumCore
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Persisted shapes

/// Everything the daemon must remember across a crash.
public struct StateSnapshot: Codable, Sendable, Equatable {
    /// Embedded copy of the schema version. The snapshot self-describes so
    /// that a crash between "migrated snapshot written" and "manifest
    /// updated" can never cause a second, corrupting migration pass.
    public var schemaVersion: Int
    public var records: [String: ServiceRecord]
    public var savedAt: Date

    public init(records: [String: ServiceRecord] = [:], savedAt: Date = Date()) {
        self.schemaVersion = StateStore.schemaVersion
        self.records = records
        self.savedAt = savedAt
    }
}

/// One line of events.jsonl: a `StateEvent` plus storage identity.
public struct PersistedEvent: Codable, Sendable, Equatable {
    public let seq: UInt64
    public let timestamp: Date
    public let kind: EventKind
    public let serviceID: String
    public let generation: UInt64
    public let detail: String?
    public let auditUser: String?
    public let auditArgv: String?

    public init(seq: UInt64, timestamp: Date, event: StateEvent) {
        self.seq = seq
        self.timestamp = timestamp
        self.kind = event.kind
        self.serviceID = event.serviceID
        self.generation = event.generation
        self.detail = event.detail
        self.auditUser = event.auditUser
        self.auditArgv = event.auditArgv
    }
}

private struct Manifest: Codable {
    var schemaVersion: Int
    var snapshotFile: String
}

// MARK: - Errors

public enum StateStoreError: Error, CustomStringConvertible, Equatable {
    /// Snapshot written by a NEWER binary — refuse rather than guess.
    case schemaTooNew(found: Int, supported: Int)
    /// No migration path from an older schema version.
    case noMigration(from: Int)
    /// state.json (or a non-final event line) failed to decode — should be
    /// impossible under the crash contract; surfaced loudly, never patched.
    case corrupt(file: String, reason: String)
    case io(String)

    public var description: String {
        switch self {
        case .schemaTooNew(let found, let supported):
            return "state schema v\(found) is newer than this binary supports (v\(supported)) — upgrade podium"
        case .noMigration(let from):
            return "no migration path from state schema v\(from)"
        case .corrupt(let file, let reason):
            return "corrupt state file \(file): \(reason)"
        case .io(let message):
            return "state store I/O error: \(message)"
        }
    }
}

// MARK: - Crash injection (tests only)

/// Simulated kill points. Internal: production code cannot inject.
enum CrashPoint: Equatable {
    case midTempWrite      // tmp file half-written, no rename
    case afterTempWrite    // tmp complete + fsync'd, no rename
    case afterRename       // rename done, directory fsync skipped
    case midEventAppend    // event line half-written (torn tail)
    case midRotation       // old archive unlinked, current log not yet renamed
}

struct SimulatedCrash: Error {}

// MARK: - The store

/// Synchronous, single-writer. The daemon (one actor) owns an instance;
/// tests hammer it directly. Not Sendable on purpose.
public final class StateStore {
    public static let schemaVersion = 1

    /// Upgrades snapshot DATA from version `key` to `key + 1`.
    public typealias Migration = @Sendable (Data) throws -> Data

    /// The state/ directory this store owns (exposed so callers can anchor
    /// sibling files like spec.applied.json).
    public let directory: URL
    private var dir: URL { directory }
    private let maxEventLogBytes: UInt64
    private let migrations: [Int: Migration]
    private var nextSeq: UInt64
    /// fsync toggle for tests that exercise atomicity logic in bulk
    /// (10k cycles); production always leaves it on.
    var fsyncEnabled = true
    /// One-shot simulated kill; consumed by the next operation that hits it.
    var crashAt: CrashPoint?

    private var manifestURL: URL { dir.appendingPathComponent("manifest.json") }
    private var snapshotURL: URL { dir.appendingPathComponent("state.json") }
    private var eventsURL: URL { dir.appendingPathComponent("events.jsonl") }
    private var rotatedURL: URL { dir.appendingPathComponent("events.jsonl.1") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]  // stable bytes, diff-friendly
        return e
    }

    /// `directory` is the stack's `state/` directory; created if missing.
    /// Opening the store recovers the event sequence counter from the log
    /// tail, so seq stays continuous across daemon restarts (and crashes).
    public init(
        directory: URL,
        maxEventLogBytes: UInt64 = 1 << 20,
        migrations: [Int: Migration] = [:]
    ) throws {
        self.directory = directory
        self.maxEventLogBytes = maxEventLogBytes
        self.migrations = migrations
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.nextSeq = 0
        try repairTornTail()
        self.nextSeq = (try lastValidSeq()).map { $0 + 1 } ?? 0
    }

    /// A writer killed mid-append leaves a torn final line (never a torn
    /// newline: each line is one write). Opening the store — which only
    /// happens after a restart — trims the tail so the next append starts
    /// on a clean boundary instead of welding onto the torn fragment.
    private func repairTornTail() throws {
        guard let data = try? Data(contentsOf: eventsURL), !data.isEmpty,
              data.last != 0x0A else { return }
        let cut = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        guard let fh = try? FileHandle(forWritingTo: eventsURL) else {
            throw StateStoreError.io("open \(eventsURL.lastPathComponent) for tail repair")
        }
        defer { try? fh.close() }
        do {
            try fh.truncate(atOffset: UInt64(cut))
            if fsyncEnabled { try fh.synchronize() }
        } catch {
            throw StateStoreError.io("tail repair: \(error)")
        }
    }

    // MARK: Snapshot

    /// Last durable snapshot, or nil for a brand-new store. Refuses newer
    /// schemas; migrates older ones (then persists the migrated form).
    public func load() throws -> StateSnapshot? {
        let manifest: Manifest
        if let manifestData = try? Data(contentsOf: manifestURL) {
            do {
                manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            } catch {
                throw StateStoreError.corrupt(file: "manifest.json", reason: "\(error)")
            }
        } else if FileManager.default.fileExists(atPath: snapshotURL.path) {
            // Crash landed between the snapshot rename and the first manifest
            // write: the snapshot is durable and must not be lost. Treat it
            // as current-version; the embedded version probe below governs.
            manifest = Manifest(schemaVersion: Self.schemaVersion, snapshotFile: "state.json")
        } else {
            return nil  // fresh store — nothing ever saved
        }
        if manifest.schemaVersion > Self.schemaVersion {
            throw StateStoreError.schemaTooNew(
                found: manifest.schemaVersion, supported: Self.schemaVersion)
        }
        let snapURL = dir.appendingPathComponent(manifest.snapshotFile)
        var data: Data
        do {
            data = try Data(contentsOf: snapURL)
        } catch {
            throw StateStoreError.corrupt(file: manifest.snapshotFile, reason: "unreadable: \(error)")
        }
        // Versioned migration chain. The version EMBEDDED in the snapshot
        // wins over the manifest: after a crash
        // mid-migration (snapshot new, manifest old) the data must not be
        // migrated twice. Pre-versioning snapshots lack the field and fall
        // back to the manifest's claim.
        struct VersionProbe: Codable { let schemaVersion: Int? }
        let embedded = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.schemaVersion
        var version = embedded ?? manifest.schemaVersion
        if version > Self.schemaVersion {
            throw StateStoreError.schemaTooNew(found: version, supported: Self.schemaVersion)
        }
        while version < Self.schemaVersion {
            guard let migrate = migrations[version] else {
                throw StateStoreError.noMigration(from: version)
            }
            data = try migrate(data)
            version += 1
        }
        let snapshot: StateSnapshot
        do {
            snapshot = try JSONDecoder().decode(StateSnapshot.self, from: data)
        } catch {
            throw StateStoreError.corrupt(file: manifest.snapshotFile, reason: "\(error)")
        }
        if manifest.schemaVersion < Self.schemaVersion {
            try save(snapshot)  // persist migrated form + current-version manifest
        }
        return snapshot
    }

    /// Atomic snapshot write: tmp → fsync → rename → dir fsync.
    public func save(_ snapshot: StateSnapshot) throws {
        let data: Data
        do {
            data = try Self.encoder().encode(snapshot)
        } catch {
            throw StateStoreError.io("encode snapshot: \(error)")
        }
        try atomicWrite(data, to: snapshotURL)
        // Manifest is tiny and changes only on schema bumps; (re)write it
        // atomically whenever missing or stale, so a fresh store becomes
        // loadable exactly when its first complete snapshot exists, and a
        // migrated store stops re-migrating on every load.
        let current = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        if current?.schemaVersion != Self.schemaVersion || current?.snapshotFile != "state.json" {
            let m = Manifest(schemaVersion: Self.schemaVersion, snapshotFile: "state.json")
            try atomicWrite(Self.encoder().encode(m), to: manifestURL)
        }
    }

    // MARK: Events

    /// Appends one event line, assigning the next sequence number.
    /// Rotation happens BEFORE the write when the log is over budget, so a
    /// line is never split across generations.
    @discardableResult
    public func append(_ event: StateEvent, at timestamp: Date = Date()) throws -> PersistedEvent {
        let persisted = PersistedEvent(seq: nextSeq, timestamp: timestamp, event: event)
        var line: Data
        do {
            line = try Self.encoder().encode(persisted)
        } catch {
            throw StateStoreError.io("encode event: \(error)")
        }
        line.append(0x0A)  // '\n'

        try rotateIfNeeded(incoming: UInt64(line.count))

        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            _ = FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: eventsURL) else {
            throw StateStoreError.io("open \(eventsURL.lastPathComponent) for append")
        }
        defer { try? fh.close() }
        do {
            _ = try fh.seekToEnd()
            if consume(.midEventAppend) {
                try fh.write(contentsOf: line.prefix(line.count / 2))
                throw SimulatedCrash()
            }
            try fh.write(contentsOf: line)
            if fsyncEnabled { try fh.synchronize() }
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            throw StateStoreError.io("append event: \(error)")
        }
        nextSeq += 1
        return persisted
    }

    /// All decodable events, rotated generation first. The only tolerated
    /// damage is a torn FINAL line per file (a crash mid-append) — anything
    /// else throws `.corrupt`.
    public func loadEvents() throws -> [PersistedEvent] {
        var events: [PersistedEvent] = []
        for url in [rotatedURL, eventsURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            events.append(contentsOf: try Self.parseLines(data, file: url.lastPathComponent))
        }
        return events
    }

    private static func parseLines(_ data: Data, file: String) throws -> [PersistedEvent] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var out: [PersistedEvent] = []
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let tornTail = data.last != 0x0A  // no trailing newline → final line torn
        for (i, lineData) in lines.enumerated() {
            do {
                out.append(try decoder.decode(PersistedEvent.self, from: lineData))
            } catch {
                let isLast = i == lines.count - 1
                if isLast && tornTail { break }  // crash mid-append; drop
                throw StateStoreError.corrupt(file: file, reason: "line \(i + 1): \(error)")
            }
        }
        return out
    }

    // MARK: - Internals

    private func rotateIfNeeded(incoming: UInt64) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: eventsURL.path)
        let currentSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize > 0, currentSize + incoming > maxEventLogBytes else { return }
        // Keep exactly one archived generation: drop .1, then rename current.
        try? FileManager.default.removeItem(at: rotatedURL)
        if consume(.midRotation) { throw SimulatedCrash() }
        if rename(eventsURL.path, rotatedURL.path) != 0 {
            throw StateStoreError.io("rotate: rename failed, errno \(errno)")
        }
        fsyncDirectory()
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let tmp = destination.appendingPathExtension("tmp")
        _ = FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: tmp) else {
            throw StateStoreError.io("open \(tmp.lastPathComponent)")
        }
        defer { try? fh.close() }
        do {
            try fh.truncate(atOffset: 0)
            if consume(.midTempWrite) {
                try fh.write(contentsOf: data.prefix(data.count / 2))
                throw SimulatedCrash()
            }
            try fh.write(contentsOf: data)
            if fsyncEnabled { try fh.synchronize() }
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            throw StateStoreError.io("write \(tmp.lastPathComponent): \(error)")
        }
        if consume(.afterTempWrite) { throw SimulatedCrash() }
        // rename(2) atomically replaces the destination (POSIX).
        if rename(tmp.path, destination.path) != 0 {
            throw StateStoreError.io("rename \(tmp.lastPathComponent): errno \(errno)")
        }
        if consume(.afterRename) { throw SimulatedCrash() }
        fsyncDirectory()
    }

    /// Make the rename itself durable (matters on Linux; harmless on APFS).
    private func fsyncDirectory() {
        guard fsyncEnabled else { return }
        let fd = open(dir.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
    }

    /// Highest seq among decodable lines, scanning current log then archive.
    private func lastValidSeq() throws -> UInt64? {
        for url in [eventsURL, rotatedURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let last = try Self.parseLines(data, file: url.lastPathComponent).last {
                return last.seq
            }
        }
        return nil
    }

    private func consume(_ point: CrashPoint) -> Bool {
        if crashAt == point {
            crashAt = nil
            return true
        }
        return false
    }
}
