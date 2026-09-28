// WireMapping.swift — proto types ↔ Wire.swift DTOs.
//
// The daemon fills proto responses from reconciler output; the CLI maps them
// back into the Wire DTOs its formatters consume. These round-trips must be
// lossless for every field a formatter reads (pinned by WireMappingTests).
//
// Conventions (podium.proto): timestamps are int64 µs since epoch, 0 = unset;
// optional strings ride as "" = unset; last_exit carries has_last_exit
// because 0 is a meaningful exit code.

import Foundation
import PodiumCore
import PodiumDaemon

// MARK: - µs-since-epoch ↔ Date?

@inline(__always)
func usec(_ date: Date?) -> Int64 {
    guard let date else { return 0 }
    return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
}

@inline(__always)
func date(fromUsec value: Int64) -> Date? {
    value == 0 ? nil : Date(timeIntervalSince1970: Double(value) / 1_000_000)
}

// MARK: - PortForward

extension PbPortForward {
    public init(_ p: PortForward) {
        self.init()
        self.hostPort = Int32(p.hostPort)
        self.containerPort = Int32(p.containerPort)
        self.bindAddress = p.bindAddress
    }

    public var wire: PortForward {
        PortForward(host: Int(hostPort), container: Int(containerPort), bindAddress: bindAddress)
    }
}

// MARK: - VolumeMount

extension PbVolumeMount {
    public init(_ v: VolumeMount) {
        self.init()
        self.source = v.source ?? ""
        self.name = v.name ?? ""
        self.destination = v.destination
        self.readOnly = v.readOnly
    }

    public var wire: VolumeMount {
        if !name.isEmpty {
            return VolumeMount(name: name, destination: destination, readOnly: readOnly)
        }
        return VolumeMount(source: source, destination: destination, readOnly: readOnly)
    }
}

// MARK: - ServiceStatus

extension PbServiceStatus {
    public init(_ s: PodiumDaemon.ServiceStatus) {
        self.init()
        self.id = s.id
        self.state = s.state
        self.ready = s.ready
        self.starts = Int32(s.starts)
        self.startedAtUsec = usec(s.startedAt)
        self.ip = s.ip ?? ""
        self.portForwards = s.portForwards.map(PbPortForward.init)
        self.schedule = s.schedule ?? ""
        self.lastRunUsec = usec(s.lastRun)
        if let exit = s.lastExit {
            self.lastExit = exit
            self.hasLastExit_p = true
        }
        self.nextRunUsec = usec(s.nextRun)
    }

    public var wire: PodiumDaemon.ServiceStatus {
        PodiumDaemon.ServiceStatus(
            id: id, state: state, ready: ready, starts: Int(starts),
            startedAt: date(fromUsec: startedAtUsec),
            ip: ip.isEmpty ? nil : ip,
            portForwards: portForwards.map(\.wire),
            schedule: schedule.isEmpty ? nil : schedule,
            lastRun: date(fromUsec: lastRunUsec),
            lastExit: hasLastExit_p ? lastExit : nil,
            nextRun: date(fromUsec: nextRunUsec)
        )
    }
}

// MARK: - PsResponse

extension PbPsResponse {
    public init(stack: String, services: [PodiumDaemon.ServiceStatus]) {
        self.init()
        self.stack = stack
        self.services = services.map(PbServiceStatus.init)
    }
}

// MARK: - DescribeResponse

extension PbDescribeResponse {
    public init(_ d: Reconciler.DescribeResult) {
        self.init()
        self.status = PbServiceStatus(ServiceStatus(
            id: d.id, state: d.state, ready: d.ready, starts: d.starts,
            startedAt: d.startedAt, ip: d.ip, portForwards: d.portForwards,
            schedule: d.schedule, lastRun: d.lastRun, lastExit: d.lastExit,
            nextRun: d.nextRun))
        self.image = d.image
        self.cpus = Int32(d.cpus)
        self.memoryMb = d.memoryMB
        self.rootfsGb = d.rootfsGB
        self.entrypoint = d.entrypoint ?? []
        self.command = d.command ?? []
        self.args = d.args ?? []
        self.hasEntrypoint_p = d.entrypoint != nil
        self.hasCommand_p = d.command != nil
        self.hasArgs_p = d.args != nil
        self.env = d.env
        self.healthCheck = d.healthCheck ?? []
        self.livenessCheck = d.livenessCheck ?? []
        self.restartPolicy = d.restartPolicy
        self.logPath = d.logPath
        self.failReason = d.failReason ?? ""
        self.volumes = d.volumes.map(PbVolumeMount.init)
    }

    /// The proto carries no stack name (the client already knows which stack
    /// it dialed); it is re-injected here. Process presence bits preserve the
    /// distinction between nil and explicit empty overrides.
    public func wire(stack: String) -> Reconciler.DescribeResult {
        let s = status.wire
        return Reconciler.DescribeResult(
            id: s.id, stack: stack, state: s.state, ready: s.ready, starts: s.starts,
            startedAt: s.startedAt, ip: s.ip, portForwards: s.portForwards,
            image: image, cpus: Int(cpus), memoryMB: memoryMb, rootfsGB: rootfsGb,
            command: hasCommand_p ? command : (command.isEmpty ? nil : command),
            entrypoint: hasEntrypoint_p ? entrypoint : (entrypoint.isEmpty ? nil : entrypoint),
            args: hasArgs_p ? args : (args.isEmpty ? nil : args),
            volumes: volumes.map(\.wire), env: env,
            healthCheck: healthCheck.isEmpty ? nil : healthCheck,
            livenessCheck: livenessCheck.isEmpty ? nil : livenessCheck,
            restartPolicy: restartPolicy, logPath: logPath,
            schedule: s.schedule, lastRun: s.lastRun, lastExit: s.lastExit,
            nextRun: s.nextRun,
            failReason: failReason.isEmpty ? nil : failReason
        )
    }
}

// MARK: - ReloadResponse ↔ StackDiff

extension PbReloadResponse {
    public init(_ diff: StackDiff) {
        self.init()
        self.started = diff.started
        self.stopped = diff.stopped
        self.restarted = diff.restarted
        self.unchanged = diff.unchanged
    }

    public var wire: StackDiff {
        StackDiff(started: started, stopped: stopped, restarted: restarted, unchanged: unchanged)
    }
}

// MARK: - StatsSample ↔ [Reconciler.StatSample]

extension PbServiceStats {
    /// `cpuPct` never rides the wire — the client computes % from cumulative
    /// deltas (proto comment). `has_cpu`/`has_mem` guard the not-running /
    /// read-failed rows whose counters are unavailable. A mem limit of
    /// 0 is "unset": cgroups report no-limit as a near-UInt64.max sentinel,
    /// never 0, so 0 is unambiguous.
    public init(_ s: Reconciler.StatSample) {
        self.init()
        self.id = s.id
        self.state = s.state
        self.cpuUsageUsec = s.cpuUsageUsec ?? 0
        self.hasCpu_p = s.cpuUsageUsec != nil
        self.memUsageBytes = s.memUsageBytes ?? 0
        self.memLimitBytes = s.memLimitBytes ?? 0
        self.hasMem_p = s.memUsageBytes != nil
        self.cpus = Int32(s.cpus)
    }

    /// `sampledAt` is frame-level on the wire; the caller passes it down.
    public func wire(sampledAtUsec: UInt64) -> Reconciler.StatSample {
        Reconciler.StatSample(
            id: id, state: state,
            cpuUsageUsec: hasCpu_p ? cpuUsageUsec : nil,
            sampledAtUsec: sampledAtUsec,
            memUsageBytes: hasMem_p ? memUsageBytes : nil,
            memLimitBytes: memLimitBytes == 0 ? nil : memLimitBytes,
            cpus: Int(cpus), cpuPct: nil)
    }
}

extension PbStatsSample {
    /// One frame. The frame timestamp is the first row's `sampledAtUsec`
    /// (rows within a sweep are sampled ms apart; intervals are seconds, so
    /// collapsing to frame level costs nothing the % math can see).
    public init(_ samples: [Reconciler.StatSample]) {
        self.init()
        self.sampledAtUsec = Int64(samples.first?.sampledAtUsec ?? 0)
        self.services = samples.map(PbServiceStats.init)
    }

    public var wireSamples: [Reconciler.StatSample] {
        services.map { $0.wire(sampledAtUsec: UInt64(sampledAtUsec)) }
    }
}

// MARK: - MetricsResponse ↔ PodiumMetrics

extension PbServiceMetric {
    public init(_ service: PodiumMetrics.Service) {
        self.init()
        id = service.id
        phase = service.phase
        starts = service.starts
        restarts = service.restarts
        if let latency = service.probeLatencySeconds {
            probeLatencySeconds = latency
            hasProbeLatency_p = true
        }
        relayConnections = service.relayConnections
    }

    public var wire: PodiumMetrics.Service {
        PodiumMetrics.Service(
            id: id, phase: phase, starts: starts, restarts: restarts,
            probeLatencySeconds: hasProbeLatency_p ? probeLatencySeconds : nil,
            relayConnections: relayConnections)
    }
}

extension PbMetricsResponse {
    public init(_ metrics: PodiumMetrics) {
        self.init()
        daemonUptimeSeconds = metrics.daemonUptimeSeconds
        services = metrics.services.map(PbServiceMetric.init)
    }

    public func wire(stack: String) -> PodiumMetrics {
        PodiumMetrics(
            stack: stack, daemonUptimeSeconds: daemonUptimeSeconds,
            services: services.map(\.wire))
    }
}

// MARK: - Event ↔ PodiumEvent

extension PbEvent {
    public init(_ e: PodiumEvent) {
        self.init()
        self.seq = UInt64(e.seq)
        self.timestampUsec = usec(e.timestamp)
        self.stack = e.stack
        self.service = e.svc
        self.type = e.type
        self.detail = e.detail ?? ""
        self.generation = e.generation
        self.auditUser = e.auditUser ?? ""
        self.auditArgv = e.auditArgv ?? ""
    }

    public var wire: PodiumEvent {
        PodiumEvent(
            seq: Int(seq),
            timestamp: date(fromUsec: timestampUsec) ?? Date(timeIntervalSince1970: 0),
            stack: stack, svc: service, type: type,
            detail: detail.isEmpty ? nil : detail,
            generation: generation,
            auditUser: auditUser.isEmpty ? nil : auditUser,
            auditArgv: auditArgv.isEmpty ? nil : auditArgv)
    }
}
