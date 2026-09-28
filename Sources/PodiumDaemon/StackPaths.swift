// StackPaths.swift — per-stack filesystem layout (~/.podium/<stack>/…).

import Foundation

public enum StackPaths {
    public static let podiumRoot: String =
        (NSHomeDirectory() as NSString).appendingPathComponent(".podium")

    /// Runtime directory for a named stack.
    public static func dir(for stackName: String) -> String {
        (podiumRoot as NSString).appendingPathComponent(safe(stackName))
    }

    /// Durable state directory (manifest.json / state.json / events.jsonl).
    public static func stateDir(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("state")
    }

    /// Unix-socket path for the stack's gRPC control plane.
    /// The socket inode is created 0600 inside the stack's 0700 runtime directory.
    public static func socketPath(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("podium.sock")
    }

    /// Private file-backed secret store for one stack. The provider requires
    /// this file to be regular, owned by the daemon user, and mode 0600.
    public static func secretsPath(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("secrets.env")
    }

    /// Structured JSON-lines supervisor log for one stack.
    public static func daemonLogPath(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("daemon.log")
    }

    /// Log file for one service inside a named stack.
    public static func logPath(for stackName: String, id: String) -> String {
        ((dir(for: stackName) as NSString).appendingPathComponent("logs") as NSString)
            .appendingPathComponent("\(id).log")
    }

    /// Rotate log files for a service before a fresh start, keeping up to `keep` prior runs.
    /// Shifts <id>.log → <id>.log.1 → .log.2 → .log.3 (dropping the oldest).
    /// After this call, the main log path is absent so `FileLogWriter` creates a fresh file.
    public static func rotateLog(for stackName: String, id: String, keep: Int = 3) {
        let fm = FileManager.default
        let base = logPath(for: stackName, id: id)
        guard fm.fileExists(atPath: base) else { return }
        try? fm.removeItem(atPath: "\(base).\(keep)")
        for n in stride(from: keep - 1, through: 1, by: -1) {
            if fm.fileExists(atPath: "\(base).\(n)") {
                try? fm.moveItem(atPath: "\(base).\(n)", toPath: "\(base).\(n + 1)")
            }
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
    }

    /// Root of a stack's managed volumes — what `down --volumes` deletes.
    public static func volumesRoot(for stackName: String) -> String {
        (dir(for: stackName) as NSString).appendingPathComponent("volumes")
    }

    /// Host path for a named managed volume in a stack.
    /// The directory is created on demand in `Reconciler.startSequence`; never auto-deleted.
    public static func volumeDir(for stackName: String, name: String) -> String {
        (volumesRoot(for: stackName) as NSString).appendingPathComponent(safe(name))
    }

    /// Sanitize a stack name for use as a directory component. Names are
    /// validated elsewhere; this is defense in depth.
    public static func safe(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-_.")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
