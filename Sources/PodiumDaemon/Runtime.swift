// The container-runtime seam. The Reconciler drives containers through this
// protocol instead of importing Containerization. The real adapter
// (`ContainerizationRuntime`, Sources/podium) is macOS-only; tests drive the
// reconciler with a scripted mock, so generation races are unit-testable.

import Foundation
import PodiumCore

/// Everything the runtime needs to create and boot one container.
/// Deliberately runtime-agnostic: no Containerization types, no closures.
public struct RuntimeContainerConfig: Sendable {
    public struct Mount: Sendable {
        public let source: String
        public let destination: String
        public let readOnly: Bool
        public init(source: String, destination: String, readOnly: Bool) {
            self.source = source
            self.destination = destination
            self.readOnly = readOnly
        }
    }

    public struct HostEntry: Sendable, Equatable {
        public let ip: String
        public let hostname: String
        public init(ip: String, hostname: String) {
            self.ip = ip
            self.hostname = hostname
        }
    }

    public struct DNSConfiguration: Sendable, Equatable {
        public let nameservers: [String]
        public let searchDomains: [String]
        public let options: [String]
        public init(nameservers: [String], searchDomains: [String] = [], options: [String] = []) {
            self.nameservers = nameservers
            self.searchDomains = searchDomains
            self.options = options
        }
    }

    public let id: String
    public let image: String
    public let cpus: Int
    public let memoryBytes: UInt64
    public let rootfsBytes: UInt64
    public let entrypoint: [String]?
    public let command: [String]?
    public let args: [String]?
    public let workingDirectory: String?
    public let env: [String]              // KEY=value, appended to image env
    public let mounts: [Mount]
    public let hostEntries: [HostEntry]   // peer service discovery /etc/hosts
    public let dns: DNSConfiguration?     // stack-local DNS resolver, when enabled
    public let logPath: String?           // stdout+stderr capture; nil = discard
    public let redactions: [String]       // secret values removed from captured logs

    public init(
        id: String, image: String, cpus: Int, memoryBytes: UInt64, rootfsBytes: UInt64,
        entrypoint: [String]? = nil, command: [String]? = nil, args: [String]? = nil,
        workingDirectory: String? = nil, env: [String] = [],
        mounts: [Mount] = [], hostEntries: [HostEntry] = [], dns: DNSConfiguration? = nil,
        logPath: String? = nil,
        redactions: [String] = []
    ) {
        self.id = id
        self.image = image
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.rootfsBytes = rootfsBytes
        self.entrypoint = entrypoint
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.env = env
        self.mounts = mounts
        self.hostEntries = hostEntries
        self.dns = dns
        self.logPath = logPath
        self.redactions = redactions
    }
}

public struct RuntimeExecResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct RuntimeStats: Sendable {
    public let cpuUsageUsec: UInt64?
    public let memUsageBytes: UInt64?
    public let memLimitBytes: UInt64?
    public init(cpuUsageUsec: UInt64?, memUsageBytes: UInt64?, memLimitBytes: UInt64?) {
        self.cpuUsageUsec = cpuUsageUsec
        self.memUsageBytes = memUsageBytes
        self.memLimitBytes = memLimitBytes
    }
}

/// A live container handle. The reconciler holds these in a runtime registry
/// (NOT in state — records carry only the container ID string).
public protocol RuntimeContainer: Sendable {
    /// vmnet IPv4 assigned at boot; stable for the container's lifetime.
    var ipAddress: String? { get }
    /// Blocks until the container exits. Never throws: a wait error is
    /// indistinguishable from a crash, so it reports exit code -1.
    func wait() async -> Int32
    func stop() async throws
    /// SIGKILL — the liveness probe's hammer.
    func kill() async throws
    func exec(id: String, argv: [String]) async throws -> RuntimeExecResult
    /// Streaming exec: tty = PTY-backed (merged output, resizable),
    /// non-tty = pipe-backed (separate stdout/stderr). Throws if the exec
    /// could not be started.
    func startExecSession(id: String, argv: [String], tty: Bool,
                          rows: UInt16, cols: UInt16) async throws -> any ExecSession
    func statistics() async throws -> RuntimeStats
    /// Streaming cp: copy a host file into the container / a container
    /// file out to the host, using the runtime's native chunked transfer.
    func importFile(hostPath: String, containerPath: String, mode: UInt32) async throws
    func exportFile(containerPath: String, hostPath: String) async throws
}

extension RuntimeContainer {
    /// Default for adapters without streaming exec.
    public func startExecSession(id: String, argv: [String], tty: Bool,
                                 rows: UInt16, cols: UInt16) async throws -> any ExecSession {
        throw ExecUnsupportedError()
    }
    /// Defaults for adapters without cp.
    public func importFile(hostPath: String, containerPath: String, mode: UInt32) async throws {
        throw ExecUnsupportedError()
    }
    public func exportFile(containerPath: String, hostPath: String) async throws {
        throw ExecUnsupportedError()
    }
}

/// A running host-side port relay; opaque to the reconciler beyond stop().
public protocol PortRelayHandle: Sendable {
    func stop()
    var connectionCount: UInt64 { get }
    var canRetarget: Bool { get }
    /// Retarget new connections without releasing the host listener.
    func retarget(ip: String) -> Bool
}

extension PortRelayHandle {
    public var connectionCount: UInt64 { 0 }
    public var canRetarget: Bool { false }
    public func retarget(ip: String) -> Bool { false }
}

/// The runtime itself: create/run/delete containers, start port relays.
public protocol ContainerRuntime: Sendable {
    /// Best-effort removal of any existing container with this ID.
    func delete(_ id: String)
    /// Create + boot a service container; returns the live handle.
    func createAndStart(_ config: RuntimeContainerConfig) async throws -> any RuntimeContainer
    /// Run an init container to completion; returns its exit code.
    func runToCompletion(_ config: RuntimeContainerConfig) async throws -> Int32
    /// Start host TCP relays for a running container. Bind failures are the
    /// adapter's to log; it returns whatever listeners did come up.
    func startPortForwards(_ forwards: [PortForward], serviceID: String, ip: String)
        -> [any PortRelayHandle]
}
