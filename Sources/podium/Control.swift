import Darwin
import Foundation
import PodiumCore
import PodiumDaemon

/// Control plane: the `apply` daemon serves a unix-domain socket, one per named stack.
/// Runtime layout:  ~/.podium/<stackName>/podium.sock   (control socket)
///                  ~/.podium/<stackName>/logs/<id>.log  (per-service stdout+stderr)
///
/// Multiple stacks can run concurrently — each gets its own directory and network
/// (separate ContainerManager ⟹ separate VmnetNetwork), so they can't cross-talk.
/// PODIUM_SOCK env var overrides socket path for scripting / non-standard layouts.
enum Control {
    static let podiumRoot: String = StackPaths.podiumRoot

    // MARK: per-stack paths (delegating to PodiumDaemon.StackPaths)

    /// Runtime directory for a named stack.
    static func dir(for stackName: String) -> String {
        StackPaths.dir(for: stackName)
    }

    /// Unix-socket path for the named stack's daemon.
    static func socketPath(for stackName: String) -> String {
        StackPaths.socketPath(for: stackName)
    }

    /// Log file for one service inside a named stack.
    static func logPath(for stackName: String, id: String) -> String {
        StackPaths.logPath(for: stackName, id: id)
    }

    /// Host path for a named managed volume in a stack.
    static func volumeDir(for stackName: String, name: String) -> String {
        StackPaths.volumeDir(for: stackName, name: name)
    }

    /// Create the runtime dir tree for a stack before the daemon starts.
    static func makeDirs(for stackName: String) throws {
        let logs = (dir(for: stackName) as NSString).appendingPathComponent("logs")
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
    }

    // MARK: instance lock

    /// Per-stack exclusive lock file. Held (flock LOCK_EX) for the lifetime of the
    /// daemon or selftest process, guaranteeing exactly one runtime per stack.
    static func lockPath(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("lock")
    }

    /// Pid of the current lock holder, recorded for diagnostics.
    static func pidPath(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("daemon.pid")
    }

    /// Try to acquire the exclusive per-stack lock. Returns the open fd on success
    /// (keep it open for the process lifetime — closing it releases the lock),
    /// or nil if another process holds it.
    static func acquireLock(for stackName: String) -> Int32? {
        try? FileManager.default.createDirectory(atPath: dir(for: stackName),
                                                 withIntermediateDirectories: true)
        let fd = open(lockPath(for: stackName), O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        try? "\(getpid())\n".write(toFile: pidPath(for: stackName), atomically: true, encoding: .utf8)
        return fd
    }

    /// True if some process currently holds the stack's lock (i.e. a daemon is running).
    static func lockIsHeld(for stackName: String) -> Bool {
        let fd = open(lockPath(for: stackName), O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// Best-effort read of the lock holder's recorded pid (diagnostics only).
    static func lockHolderPid(for stackName: String) -> String? {
        (try? String(contentsOfFile: pidPath(for: stackName), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: client-side resolution

    /// Resolve which socket a client command should connect to.
    ///
    /// Priority: PODIUM_SOCK env var → explicit stackName → auto-detect (exactly one live stack).
    /// Returns `nil` when auto-detect finds zero or multiple stacks (caller should report error).
    static func resolve(stackName: String?) -> String? {
        if let p = ProcessInfo.processInfo.environment["PODIUM_SOCK"], !p.isEmpty { return p }
        if let n = stackName { return socketPath(for: n) }
        let live = activeStacks()
        return live.count == 1 ? live[0].socket : nil
    }

    /// Find the log file for a service, either in an explicit stack or by scanning all stacks.
    static func resolveLog(stackName: String?, id: String) -> String? {
        if let n = stackName { return logPath(for: n, id: id) }
        // Auto-detect: return first match across all stack dirs.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: podiumRoot) else { return nil }
        for entry in entries.sorted() {
            let path = logPath(for: entry, id: id)
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// All stacks that currently have a socket file on disk (may include stale/crashed daemons).
    static func activeStacks() -> [(name: String, socket: String)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: podiumRoot) else { return [] }
        return entries.sorted().compactMap { entry in
            let sock = socketPath(for: entry)
            guard fm.fileExists(atPath: sock) else { return nil }
            return (name: entry, socket: sock)
        }
    }

    /// Socket-bearing stacks whose instance lock is not held. Diagnostic only;
    /// pruning reacquires the lock so this observation cannot cause a race.
    static func staleStacks() -> [String] {
        activeStacks().map(\.name).filter { !lockIsHeld(for: $0) }
    }

    /// Acquire the same exclusive instance lock a daemon would use, then
    /// remove only its stale socket/pid. The lock inode itself stays in place;
    /// removing a held flock inode would allow a split-brain replacement.
    static func pruneStaleStack(_ stackName: String) -> [String]? {
        let lock = lockPath(for: stackName)
        let fd = open(lock, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try? StaleStackFiles.prune(
            directory: URL(fileURLWithPath: dir(for: stackName)))
    }

}
