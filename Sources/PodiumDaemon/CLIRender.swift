// CLIRender.swift — the CLI's human-readable output for ps / describe /
// diff / reload / events / metrics, pinned by CLIRenderTests snapshots.
//
// Every renderer takes `now` so tests are deterministic, and returns
// newline-joined text that callers print() once.

import Foundation
import PodiumCore

public enum CLIRender {

    // MARK: metrics

    public static func metrics(_ metrics: PodiumMetrics) -> String {
        func label(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        func labels(_ service: PodiumMetrics.Service, includePhase: Bool = false) -> String {
            var parts = ["stack=\"\(label(metrics.stack))\"", "service=\"\(label(service.id))\""]
            if includePhase { parts.append("phase=\"\(label(service.phase))\"") }
            return "{" + parts.joined(separator: ",") + "}"
        }

        var lines = [
            "# HELP podium_daemon_uptime_seconds Podium daemon uptime.",
            "# TYPE podium_daemon_uptime_seconds gauge",
            "podium_daemon_uptime_seconds{stack=\"\(label(metrics.stack))\"} \(metrics.daemonUptimeSeconds)",
            "# HELP podium_service_phase Current service phase (1 for the labeled phase).",
            "# TYPE podium_service_phase gauge",
            "# HELP podium_service_starts_total Durable service start attempts.",
            "# TYPE podium_service_starts_total counter",
            "# HELP podium_service_restarts_total Service starts after the first start.",
            "# TYPE podium_service_restarts_total counter",
            "# HELP podium_service_probe_latency_seconds Last readiness or liveness probe latency.",
            "# TYPE podium_service_probe_latency_seconds gauge",
            "# HELP podium_relay_connections_total Accepted host relay connections.",
            "# TYPE podium_relay_connections_total counter",
        ]
        for service in metrics.services.sorted(by: { $0.id < $1.id }) {
            lines.append("podium_service_phase\(labels(service, includePhase: true)) 1")
            lines.append("podium_service_starts_total\(labels(service)) \(service.starts)")
            lines.append("podium_service_restarts_total\(labels(service)) \(service.restarts)")
            if let latency = service.probeLatencySeconds {
                lines.append("podium_service_probe_latency_seconds\(labels(service)) \(latency)")
            }
            lines.append("podium_relay_connections_total\(labels(service)) \(service.relayConnections)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: ps

    public static func ps(stack: String, services: [ServiceStatus], now: Date = Date()) -> String {
        // Format ADDRESS column.
        // - With host port bindings: "*:8080 192.168.64.3:80"
        // - Without bindings, with IP: "192.168.64.3:80,443" or just "192.168.64.3"
        // - Not running: "—"
        func address(_ s: ServiceStatus) -> String {
            guard let ip = s.ip else { return "—" }
            let pf = s.portForwards
            if pf.isEmpty { return ip }
            return pf.map { "\($0.bindDisplay):\($0.hostPort) \(ip):\($0.containerPort)" }.joined(separator: "  ")
        }

        var lines: [String] = ["STACK \(stack)"]
        let hasCron = services.contains { $0.schedule != nil }
        if hasCron {
            // Extended table for stacks that contain cron services.
            lines.append("SERVICE".padding(toLength: 22, withPad: " ", startingAt: 0)
                + "STATE".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "ADDRESS".padding(toLength: 22, withPad: " ", startingAt: 0)
                + "FIRES  LAST RUN     NEXT RUN    SCHEDULE")
            for s in services {
                if let schedule = s.schedule {
                    let lastRunStr = s.lastRun.map { age($0, now: now) + " ago" } ?? "never"
                    let nextRunStr = s.state == "running" ? "running" :
                                    s.nextRun.map { inDuration($0, now: now) } ?? "-"
                    let exitStr    = s.lastExit.map { $0 == 0 ? "" : "  (exit \($0))" } ?? ""
                    lines.append(s.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                        + s.state.padding(toLength: 12, withPad: " ", startingAt: 0)
                        + address(s).padding(toLength: 22, withPad: " ", startingAt: 0)
                        + "\(s.starts)".padding(toLength: 7, withPad: " ", startingAt: 0)
                        + lastRunStr.padding(toLength: 13, withPad: " ", startingAt: 0)
                        + nextRunStr.padding(toLength: 12, withPad: " ", startingAt: 0)
                        + schedule + exitStr)
                } else {
                    let uptime = s.startedAt.map { age($0, now: now) } ?? "-"
                    lines.append(s.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                        + s.state.padding(toLength: 12, withPad: " ", startingAt: 0)
                        + address(s).padding(toLength: 22, withPad: " ", startingAt: 0)
                        + "\(s.starts)".padding(toLength: 7, withPad: " ", startingAt: 0)
                        + uptime.padding(toLength: 13, withPad: " ", startingAt: 0)
                        + "-".padding(toLength: 12, withPad: " ", startingAt: 0)
                        + (s.ready ? "healthy" : "not ready"))
                }
            }
        } else {
            // Standard table for all-regular stacks.
            lines.append("SERVICE".padding(toLength: 22, withPad: " ", startingAt: 0)
                + "STATE".padding(toLength: 10, withPad: " ", startingAt: 0)
                + "READY  STARTS  AGE     ADDRESS")
            for s in services {
                let uptime = s.startedAt.map { age($0, now: now) } ?? "-"
                lines.append(s.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                    + s.state.padding(toLength: 10, withPad: " ", startingAt: 0)
                    + (s.ready ? "yes" : "no ").padding(toLength: 7, withPad: " ", startingAt: 0)
                    + "\(s.starts)".padding(toLength: 7, withPad: " ", startingAt: 0)
                    + uptime.padding(toLength: 8, withPad: " ", startingAt: 0)
                    + address(s))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: describe

    public static func describe(_ d: Reconciler.DescribeResult, now: Date = Date()) -> String {
        var lines: [String] = []
        let uptime = d.startedAt.map { "started: \(age($0, now: now)) ago" } ?? "not started"
        lines.append("SERVICE  \(d.id)  [stack: \(d.stack)]")
        lines.append("state:   \(d.state)  \(uptime)  starts: \(d.starts)")
        if let fr = d.failReason { lines.append("reason:  \(fr)") }
        if let ip = d.ip {
            let portLines = d.portForwards.map { "  \($0.bindDisplay):\($0.hostPort) → \(ip):\($0.containerPort)" }
            lines.append("ip:      \(ip)")
            if !d.portForwards.isEmpty {
                lines.append("forward:\(portLines.joined(separator: "\n        "))")
            } else {
                lines.append("reachable: \(ip)")
            }
        } else if !d.portForwards.isEmpty {
            let portLines = d.portForwards.map { "\($0.bindDisplay):\($0.hostPort) → :\($0.containerPort)" }
            lines.append("ports:   \(portLines.joined(separator: ", "))  (not running)")
        }
        lines.append("image:   \(d.image)")
        let rootfs = d.rootfsGB == 1 ? "1 GiB" : "\(d.rootfsGB) GiB"
        lines.append("cpus:    \(d.cpus)  memory: \(d.memoryMB) MiB  rootfs: \(rootfs)")
        if !d.volumes.isEmpty {
            for v in d.volumes {
                let src = v.source ?? StackPaths.volumeDir(for: d.stack, name: v.name ?? "?")
                let managed = v.name != nil ? " [managed]" : ""
                let ro = v.readOnly ? " [ro]" : ""
                lines.append("volume:  \(src) → \(v.destination)\(managed)\(ro)")
            }
        }
        if !d.env.isEmpty {
            let pairs = d.env.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
            lines.append("env:     \(pairs)")
        }
        if let hc = d.healthCheck {
            let readinessLabel = d.livenessCheck != nil ? "startup " : ""
            lines.append("health:  \(d.ready ? "passing" : "unknown")  \(readinessLabel)check: \(hc.joined(separator: " "))")
        }
        if let lc = d.livenessCheck {
            lines.append("liveness: \(lc.joined(separator: " "))")
        }
        if let entrypoint = d.entrypoint {
            lines.append("entrypoint: \(entrypoint.joined(separator: " "))")
        }
        if let cmd = d.command { lines.append("command: \(cmd.joined(separator: " "))") }
        if let args = d.args { lines.append("args:    \(args.joined(separator: " "))") }
        if let schedule = d.schedule {
            lines.append("schedule: \(schedule)")
            let lastRunStr = d.lastRun.map { age($0, now: now) + " ago" } ?? "never"
            let lastExitStr = d.lastExit.map { "  exit: \($0)" } ?? ""
            let nextRunStr = d.nextRun.map { inDuration($0, now: now) } ?? "-"
            lines.append("last run: \(lastRunStr)\(lastExitStr)  next: \(nextRunStr)")
        } else {
            lines.append("restart: \(d.restartPolicy)")
        }
        lines.append("log:     \(d.logPath)")
        return lines.joined(separator: "\n")
    }

    // MARK: diff

    public static func diff(_ d: StackDiff) -> String {
        var lines: [String] = []
        for s in d.restarted { lines.append("~ restart  \(s)  (spec changed)") }
        for s in d.started   { lines.append("+ start    \(s)  (new)") }
        for s in d.stopped   { lines.append("- stop     \(s)  (removed)") }
        let n = d.unchanged.count
        if d.restarted.isEmpty && d.started.isEmpty && d.stopped.isEmpty {
            lines.append("no changes (\(n) service(s) unchanged)")
        } else {
            lines.append("(\(n) unchanged)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: events

    /// One `podium events` line. `timeZone` is injectable for the snapshot
    /// tests; the CLI renders in local time.
    public static func event(_ e: PodiumEvent, timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        var suffix = e.detail.map { "  \($0)" } ?? ""
        if let user = e.auditUser { suffix += "  user=\(user)" }
        if let argv = e.auditArgv { suffix += "  argv=\(argv)" }
        return "\(fmt.string(from: e.timestamp))  \(e.svc.padding(toLength: 18, withPad: " ", startingAt: 0))  \(e.type)\(suffix)"
    }

    // MARK: reload

    public static func reload(_ d: StackDiff) -> String {
        var lines: [String] = ["reload ok"]
        func fmt(_ label: String, _ ids: [String]) {
            if !ids.isEmpty { lines.append("  \(label): \(ids.joined(separator: ", "))") }
        }
        fmt("started",   d.started)
        fmt("stopped",   d.stopped)
        fmt("restarted", d.restarted)
        fmt("unchanged", d.unchanged)
        return lines.joined(separator: "\n")
    }
}
