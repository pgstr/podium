// Wire.swift — control-plane DTOs shared by daemon and CLI client.
// The control plane maps these domain values to generated proto types.

import Foundation
import PodiumCore

/// A point-in-time view of one service, returned over the control socket.
public struct ServiceStatus: Codable, Sendable {
    public let id: String
    public let state: String       // running | failed | stopped | exited | waiting | backoff | pending | scheduled
    public let ready: Bool
    public let starts: Int
    public let startedAt: Date?    // nil when not running
    // Network fields.
    public let ip: String?                  // vmnet IPv4 while running, nil otherwise
    public let portForwards: [PortForward]  // active host↔container port mappings
    // Cron-only fields (nil for regular services).
    public let schedule: String?   // the cron expression, e.g. "0 2 * * *"
    public let lastRun: Date?      // when the job last fired
    public let lastExit: Int32?    // exit code of the last run
    public let nextRun: Date?      // next scheduled fire (nil while running or for non-cron services)

    /// Single init — network and cron fields default to nil/empty for regular services.
    public init(id: String, state: String, ready: Bool, starts: Int, startedAt: Date?,
                ip: String? = nil, portForwards: [PortForward] = [],
                schedule: String? = nil, lastRun: Date? = nil,
                lastExit: Int32? = nil, nextRun: Date? = nil) {
        self.id = id; self.state = state; self.ready = ready
        self.starts = starts; self.startedAt = startedAt
        self.ip = ip; self.portForwards = portForwards
        self.schedule = schedule; self.lastRun = lastRun
        self.lastExit = lastExit; self.nextRun = nextRun
    }

    // Custom decode applies defaults for optional runtime fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self,  forKey: .id)
        state      = try c.decode(String.self,  forKey: .state)
        ready      = try c.decode(Bool.self,    forKey: .ready)
        starts     = try c.decode(Int.self,     forKey: .starts)
        startedAt  = try c.decodeIfPresent(Date.self,   forKey: .startedAt)
        ip         = try c.decodeIfPresent(String.self, forKey: .ip)
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        schedule   = try c.decodeIfPresent(String.self, forKey: .schedule)
        lastRun    = try c.decodeIfPresent(Date.self,   forKey: .lastRun)
        lastExit   = try c.decodeIfPresent(Int32.self,  forKey: .lastExit)
        nextRun    = try c.decodeIfPresent(Date.self,   forKey: .nextRun)
    }

    enum CodingKeys: String, CodingKey {
        case id, state, ready, starts, startedAt, ip, portForwards
        case schedule, lastRun, lastExit, nextRun
    }
}

/// An event emitted by the reconciler, persisted to events.jsonl and served by
/// `podium events`. The monotonically increasing sequence number lets clients
/// resume after a known event.
public struct PodiumEvent: Codable, Sendable {
    public let seq: Int
    public let timestamp: Date
    public let stack: String
    public let svc: String
    /// Event type: starting | started | exited | crashed | healthy | unhealthy | unready
    ///             | backoff | failed | cron-fired | cron-done | stopped | scheduled
    public let type: String
    public let detail: String?   // e.g. "exit 1", "backoff 4s (attempt 2/5)", schedule expression
    /// Service incarnation that emitted the event; 0 when not recorded.
    public let generation: UInt64
    public let auditUser: String?
    public let auditArgv: String?

    public init(seq: Int, timestamp: Date, stack: String, svc: String, type: String,
                detail: String?, generation: UInt64 = 0,
                auditUser: String? = nil, auditArgv: String? = nil) {
        self.seq = seq
        self.timestamp = timestamp
        self.stack = stack
        self.svc = svc
        self.type = type
        self.detail = detail
        self.generation = generation
        self.auditUser = auditUser
        self.auditArgv = auditArgv
    }

    enum CodingKeys: String, CodingKey {
        case seq, timestamp, stack, svc, type, detail, generation, auditUser, auditArgv
    }
}

/// Point-in-time operability metrics returned by the unary Metrics RPC.
public struct PodiumMetrics: Codable, Sendable, Equatable {
    public struct Service: Codable, Sendable, Equatable {
        public let id: String
        public let phase: String
        public let starts: UInt64
        public let restarts: UInt64
        public let probeLatencySeconds: Double?
        public let relayConnections: UInt64

        public init(id: String, phase: String, starts: UInt64, restarts: UInt64,
                    probeLatencySeconds: Double?, relayConnections: UInt64) {
            self.id = id
            self.phase = phase
            self.starts = starts
            self.restarts = restarts
            self.probeLatencySeconds = probeLatencySeconds
            self.relayConnections = relayConnections
        }
    }

    public let stack: String
    public let daemonUptimeSeconds: Double
    public let services: [Service]

    public init(stack: String, daemonUptimeSeconds: Double, services: [Service]) {
        self.stack = stack
        self.daemonUptimeSeconds = daemonUptimeSeconds
        self.services = services
    }
}
