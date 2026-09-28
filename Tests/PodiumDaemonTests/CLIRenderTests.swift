// CLIRenderTests.swift — snapshot tests pinning the CLI's human-readable
// output for ps / describe / diff / reload. These snapshots are the contract
// any transport or refactor must keep. Expected
// strings are built as line arrays joined with \n so trailing-space-significant
// columns survive editors and linters.

import Foundation
import PodiumCore
import XCTest

@testable import PodiumDaemon

final class CLIRenderTests: XCTestCase {

    /// Fixed clock so age()/inDuration() are deterministic.
    let now = Date(timeIntervalSince1970: 1_755_000_000)

    func testMetricsPrometheusText() {
        let metrics = PodiumMetrics(
            stack: "home\"lab", daemonUptimeSeconds: 42.5,
            services: [
                .init(id: "web", phase: "running", starts: 2, restarts: 1,
                      probeLatencySeconds: 0.012, relayConnections: 9),
                .init(id: "job", phase: "scheduled", starts: 4, restarts: 3,
                      probeLatencySeconds: nil, relayConnections: 0),
            ])
        let rendered = CLIRender.metrics(metrics)
        XCTAssertTrue(rendered.contains("# TYPE podium_daemon_uptime_seconds gauge"))
        XCTAssertTrue(rendered.contains(
            "podium_daemon_uptime_seconds{stack=\"home\\\"lab\"} 42.5"))
        XCTAssertTrue(rendered.contains(
            "podium_service_phase{stack=\"home\\\"lab\",service=\"web\",phase=\"running\"} 1"))
        XCTAssertTrue(rendered.contains(
            "podium_service_probe_latency_seconds{stack=\"home\\\"lab\",service=\"web\"} 0.012"))
        XCTAssertFalse(rendered.contains(
            "podium_service_probe_latency_seconds{stack=\"home\\\"lab\",service=\"job\"}"))
        XCTAssertTrue(rendered.contains(
            "podium_relay_connections_total{stack=\"home\\\"lab\",service=\"web\"} 9"))
    }

    // MARK: ps — standard table (no cron services)

    func testPsStandardTable() {
        let services = [
            ServiceStatus(
                id: "web", state: "running", ready: true, starts: 3,
                startedAt: now.addingTimeInterval(-3725),
                ip: "192.168.64.3",
                portForwards: [PortForward(host: 8080, container: 80)]),
            ServiceStatus(
                id: "worker", state: "exited", ready: false, starts: 1,
                startedAt: nil),
        ]
        let expected = [
            "STACK demo",
            "SERVICE               STATE     READY  STARTS  AGE     ADDRESS",
            "web                   running   yes    3      1h2m    127.0.0.1:8080 192.168.64.3:80",
            "worker                exited    no     1      -       —",
        ].joined(separator: "\n")
        XCTAssertEqual(CLIRender.ps(stack: "demo", services: services, now: now), expected)
    }

    // MARK: ps — extended table (stack contains cron services)

    func testPsCronTable() {
        let services = [
            ServiceStatus(
                id: "web", state: "running", ready: true, starts: 3,
                startedAt: now.addingTimeInterval(-3725),
                ip: "192.168.64.3"),
            ServiceStatus(
                id: "backup", state: "scheduled", ready: false, starts: 12,
                startedAt: nil,
                schedule: "0 2 * * *",
                lastRun: now.addingTimeInterval(-7200),
                lastExit: 0,
                nextRun: now.addingTimeInterval(3600)),
            ServiceStatus(
                id: "report", state: "failed", ready: false, starts: 3,
                startedAt: nil,
                schedule: "*/5 * * * *",
                lastRun: now.addingTimeInterval(-90),
                lastExit: 7,
                nextRun: nil),
        ]
        let expected = [
            "STACK demo",
            "SERVICE               STATE       ADDRESS               FIRES  LAST RUN     NEXT RUN    SCHEDULE",
            "web                   running     192.168.64.3          3      1h2m         -           healthy",
            "backup                scheduled   —                     12     2h0m ago     in 1h       0 2 * * *",
            "report                failed      —                     3      1m ago       -           */5 * * * *  (exit 7)",
        ].joined(separator: "\n")
        XCTAssertEqual(CLIRender.ps(stack: "demo", services: services, now: now), expected)
    }

    // MARK: describe — running service, every optional populated

    func testDescribeRunningFull() {
        let d = Reconciler.DescribeResult(
            id: "web", stack: "demo", state: "running", ready: true, starts: 3,
            startedAt: now.addingTimeInterval(-3725),
            ip: "192.168.64.3",
            portForwards: [
                PortForward(host: 8080, container: 80),
                PortForward(host: 8443, container: 443, bindAddress: "0.0.0.0"),
            ],
            image: "nginx:1.27", cpus: 2, memoryMB: 512, rootfsGB: 1,
            command: ["worker"], entrypoint: ["/init", "/wrapper"], args: ["run"],
            volumes: [
                VolumeMount(source: "/srv/data", destination: "/data", readOnly: true),
                VolumeMount(name: "state", destination: "/var/lib/state"),
            ],
            env: ["B": "2", "A": "1"],
            healthCheck: ["curl", "-f", "http://localhost/"],
            livenessCheck: ["curl", "-f", "http://localhost/live"],
            restartPolicy: "always", logPath: "/Users/x/.podium/demo/logs/web.log",
            schedule: nil, lastRun: nil, lastExit: nil, nextRun: nil,
            failReason: nil)
        let managedSrc = StackPaths.volumeDir(for: "demo", name: "state")
        let expected = [
            "SERVICE  web  [stack: demo]",
            "state:   running  started: 1h2m ago  starts: 3",
            "ip:      192.168.64.3",
            "forward:  127.0.0.1:8080 → 192.168.64.3:80",
            "          *:8443 → 192.168.64.3:443",
            "image:   nginx:1.27",
            "cpus:    2  memory: 512 MiB  rootfs: 1 GiB",
            "volume:  /srv/data → /data [ro]",
            "volume:  \(managedSrc) → /var/lib/state [managed]",
            "env:     A=1  B=2",
            "health:  passing  startup check: curl -f http://localhost/",
            "liveness: curl -f http://localhost/live",
            "entrypoint: /init /wrapper",
            "command: worker",
            "args:    run",
            "restart: always",
            "log:     /Users/x/.podium/demo/logs/web.log",
        ].joined(separator: "\n")
        XCTAssertEqual(CLIRender.describe(d, now: now), expected)
    }

    // MARK: describe — cron service, not running, failed

    func testDescribeCronNotRunning() {
        let d = Reconciler.DescribeResult(
            id: "backup", stack: "demo", state: "scheduled", ready: false, starts: 12,
            startedAt: nil, ip: nil,
            portForwards: [PortForward(host: 9000, container: 9000)],
            image: "backup:latest", cpus: 1, memoryMB: 256, rootfsGB: 2,
            command: nil, volumes: [], env: [:],
            healthCheck: nil, livenessCheck: nil,
            restartPolicy: "no", logPath: "/tmp/b.log",
            schedule: "0 2 * * *",
            lastRun: now.addingTimeInterval(-7200),
            lastExit: 1,
            nextRun: now.addingTimeInterval(3600),
            failReason: "boom")
        let expected = [
            "SERVICE  backup  [stack: demo]",
            "state:   scheduled  not started  starts: 12",
            "reason:  boom",
            "ports:   127.0.0.1:9000 → :9000  (not running)",
            "image:   backup:latest",
            "cpus:    1  memory: 256 MiB  rootfs: 2 GiB",
            "schedule: 0 2 * * *",
            "last run: 2h0m ago  exit: 1  next: in 1h",
            "log:     /tmp/b.log",
        ].joined(separator: "\n")
        XCTAssertEqual(CLIRender.describe(d, now: now), expected)
    }

    // MARK: diff

    func testDiffWithChanges() {
        let d = StackDiff(
            started: ["new1"], stopped: ["old1"],
            restarted: ["web"], unchanged: ["db", "cache"])
        let expected = [
            "~ restart  web  (spec changed)",
            "+ start    new1  (new)",
            "- stop     old1  (removed)",
            "(2 unchanged)",
        ].joined(separator: "\n")
        XCTAssertEqual(CLIRender.diff(d), expected)
    }

    func testDiffNoChanges() {
        let d = StackDiff(started: [], stopped: [], restarted: [], unchanged: ["a", "b", "c"])
        XCTAssertEqual(CLIRender.diff(d), "no changes (3 service(s) unchanged)")
    }

    // MARK: events

    func testEventLine() {
        let utc = TimeZone(identifier: "UTC")!
        // 1_755_000_000 = 2025-08-12 12:00:00 UTC
        let withDetail = PodiumEvent(seq: 7, timestamp: now, stack: "demo", svc: "web",
                                     type: "backoff", detail: "backoff 4s (attempt 2/5)")
        XCTAssertEqual(CLIRender.event(withDetail, timeZone: utc),
                       "12:00:00  web                 backoff  backoff 4s (attempt 2/5)")
        let noDetail = PodiumEvent(seq: 8, timestamp: now.addingTimeInterval(61), stack: "demo",
                                   svc: "cron-job", type: "started", detail: nil)
        XCTAssertEqual(CLIRender.event(noDetail, timeZone: utc),
                       "12:01:01  cron-job            started")
        // Long ids truncate at 18 — same as the poll loop always did.
        let longID = PodiumEvent(seq: 9, timestamp: now, stack: "demo",
                                 svc: "a-very-long-service-name", type: "stopped", detail: nil)
        XCTAssertEqual(CLIRender.event(longID, timeZone: utc),
                       "12:00:00  a-very-long-servic  stopped")

        let audit = PodiumEvent(
            seq: 10, timestamp: now, stack: "demo", svc: "@stack",
            type: "audit", detail: "down", auditUser: "alice",
            auditArgv: "podium down --volumes -y")
        XCTAssertEqual(CLIRender.event(audit, timeZone: utc),
                       "12:00:00  @stack              audit  down  user=alice  argv=podium down --volumes -y")
    }

    // MARK: reload

    func testReloadAllBuckets() {
        let d = StackDiff(
            started: ["a"], stopped: ["b"], restarted: ["c", "d"], unchanged: ["e"])
        let expected = [
            "reload ok",
            "  started: a",
            "  stopped: b",
            "  restarted: c, d",
            "  unchanged: e",
        ].joined(separator: "\n")
        XCTAssertEqual(CLIRender.reload(d), expected)
    }

    func testReloadNoChanges() {
        let d = StackDiff(started: [], stopped: [], restarted: [], unchanged: ["web", "db"])
        XCTAssertEqual(CLIRender.reload(d), "reload ok\n  unchanged: web, db")
    }
}
