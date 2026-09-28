// WireMappingTests.swift — the proto↔Wire round-trip
// must be lossless for every field the CLI formatters read, because byte-
// identical CLI output is derived from (same DTO in) + (same formatter).
// Timestamps go through µs-since-epoch, so equality is asserted at µs
// precision, which is finer than anything the formatters print.

import Foundation
import XCTest
import PodiumCore
import PodiumDaemon
import PodiumRPC

final class WireMappingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_752_300_000.123456)
    private let t1 = Date(timeIntervalSince1970: 1_752_303_600.5)

    private func assertStatusEqual(
        _ a: PodiumDaemon.ServiceStatus, _ b: PodiumDaemon.ServiceStatus,
        _ note: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.id, b.id, note, file: file, line: line)
        XCTAssertEqual(a.state, b.state, note, file: file, line: line)
        XCTAssertEqual(a.ready, b.ready, note, file: file, line: line)
        XCTAssertEqual(a.starts, b.starts, note, file: file, line: line)
        assertDateEqual(a.startedAt, b.startedAt, note, file: file, line: line)
        XCTAssertEqual(a.ip, b.ip, note, file: file, line: line)
        XCTAssertEqual(a.portForwards, b.portForwards, note, file: file, line: line)
        XCTAssertEqual(a.schedule, b.schedule, note, file: file, line: line)
        assertDateEqual(a.lastRun, b.lastRun, note, file: file, line: line)
        XCTAssertEqual(a.lastExit, b.lastExit, note, file: file, line: line)
        assertDateEqual(a.nextRun, b.nextRun, note, file: file, line: line)
    }

    private func assertDateEqual(
        _ a: Date?, _ b: Date?, _ note: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch (a, b) {
        case (nil, nil): return
        case (let a?, let b?):
            XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970,
                           accuracy: 0.000_002, note, file: file, line: line)
        default:
            XCTFail("\(note): \(String(describing: a)) != \(String(describing: b))",
                    file: file, line: line)
        }
    }

    // MARK: ServiceStatus

    func testServiceStatusRoundTripFull() {
        let full = PodiumDaemon.ServiceStatus(
            id: "web", state: "running", ready: true, starts: 7, startedAt: t0,
            ip: "192.168.64.3",
            portForwards: [PortForward(host: 8080, container: 80),
                           PortForward(host: 8443, container: 443, bindAddress: "0.0.0.0")],
            schedule: "0 2 * * *", lastRun: t0, lastExit: 0, nextRun: t1)
        assertStatusEqual(PbServiceStatus(full).wire, full, "full status")
        // lastExit == 0 must survive: it rides has_last_exit, not magic zero.
        XCTAssertEqual(PbServiceStatus(full).wire.lastExit, 0)
    }

    func testServiceStatusRoundTripMinimal() {
        let minimal = PodiumDaemon.ServiceStatus(
            id: "db", state: "stopped", ready: false, starts: 0, startedAt: nil)
        assertStatusEqual(PbServiceStatus(minimal).wire, minimal, "minimal status")
        let pb = PbServiceStatus(minimal)
        XCTAssertFalse(pb.hasLastExit_p)
        XCTAssertEqual(pb.startedAtUsec, 0)
        XCTAssertEqual(pb.ip, "")
    }

    // MARK: DescribeResponse

    func testDescribeRoundTripFull() {
        let d = Reconciler.DescribeResult(
            id: "web", stack: "demo", state: "running", ready: true, starts: 3,
            startedAt: t0, ip: "192.168.64.9",
            portForwards: [PortForward(host: 8080, container: 80)],
            image: "nginx:1.27", cpus: 2, memoryMB: 512, rootfsGB: 2,
            command: ["worker"], entrypoint: ["/init", "/wrapper"], args: ["run"],
            volumes: [VolumeMount(source: "/srv/www", destination: "/usr/share/nginx/html", readOnly: true),
                      VolumeMount(name: "data", destination: "/var/lib/data")],
            env: ["A": "1", "B": "two words"],
            healthCheck: ["curl", "-f", "http://localhost/"],
            livenessCheck: ["true"],
            restartPolicy: "always", logPath: "/Users/x/.podium/demo/logs/web.log",
            schedule: nil, lastRun: nil, lastExit: nil, nextRun: nil,
            failReason: nil)
        let back = PbDescribeResponse(d).wire(stack: "demo")
        XCTAssertEqual(back.id, d.id)
        XCTAssertEqual(back.stack, d.stack)
        XCTAssertEqual(back.state, d.state)
        XCTAssertEqual(back.ready, d.ready)
        XCTAssertEqual(back.starts, d.starts)
        assertDateEqual(back.startedAt, d.startedAt)
        XCTAssertEqual(back.ip, d.ip)
        XCTAssertEqual(back.portForwards, d.portForwards)
        XCTAssertEqual(back.image, d.image)
        XCTAssertEqual(back.cpus, d.cpus)
        XCTAssertEqual(back.memoryMB, d.memoryMB)
        XCTAssertEqual(back.rootfsGB, d.rootfsGB)
        XCTAssertEqual(back.entrypoint, d.entrypoint)
        XCTAssertEqual(back.command, d.command)
        XCTAssertEqual(back.args, d.args)
        XCTAssertEqual(back.volumes, d.volumes)
        XCTAssertEqual(back.env, d.env)
        XCTAssertEqual(back.healthCheck, d.healthCheck)
        XCTAssertEqual(back.livenessCheck, d.livenessCheck)
        XCTAssertEqual(back.restartPolicy, d.restartPolicy)
        XCTAssertEqual(back.logPath, d.logPath)
        XCTAssertNil(back.schedule)
        XCTAssertNil(back.failReason)
    }

    func testDescribeRoundTripFailedCron() {
        let d = Reconciler.DescribeResult(
            id: "backup", stack: "demo", state: "failed", ready: false, starts: 5,
            startedAt: nil, ip: nil, portForwards: [],
            image: "backup:latest", cpus: 1, memoryMB: 256, rootfsGB: 1,
            command: nil, volumes: [], env: [:],
            healthCheck: nil, livenessCheck: nil,
            restartPolicy: "on-failure", logPath: "/x/backup.log",
            schedule: "0 2 * * *", lastRun: t0, lastExit: 1, nextRun: t1,
            failReason: "exit 1 (exhausted 5 retries)")
        let back = PbDescribeResponse(d).wire(stack: "demo")
        XCTAssertEqual(back.schedule, d.schedule)
        assertDateEqual(back.lastRun, d.lastRun)
        XCTAssertEqual(back.lastExit, 1)
        assertDateEqual(back.nextRun, d.nextRun)
        XCTAssertEqual(back.failReason, d.failReason)
        XCTAssertNil(back.entrypoint)
        XCTAssertNil(back.command)
        XCTAssertNil(back.args)
        XCTAssertNil(back.healthCheck)
        XCTAssertNil(back.livenessCheck)
        XCTAssertNil(back.ip)
        XCTAssertEqual(back.env, [:])
    }

    func testDescribeRoundTripPreservesExplicitEmptyProcessOverrides() {
        let d = Reconciler.DescribeResult(
            id: "empty", stack: "s", state: "running", ready: true, starts: 1,
            startedAt: t0, ip: nil, portForwards: [], image: "img",
            cpus: 1, memoryMB: 128, rootfsGB: 1,
            command: [], entrypoint: [], args: [], volumes: [], env: [:],
            healthCheck: nil, livenessCheck: nil, restartPolicy: "no", logPath: "/x",
            schedule: nil, lastRun: nil, lastExit: nil, nextRun: nil, failReason: nil)
        let back = PbDescribeResponse(d).wire(stack: "s")
        XCTAssertEqual(back.command, [])
        XCTAssertEqual(back.entrypoint, [])
        XCTAssertEqual(back.args, [])
    }

    // MARK: ReloadResponse / StackDiff

    func testStackDiffRoundTripPreservesOrder() {
        let diff = StackDiff(started: ["c", "a"], stopped: ["z"],
                             restarted: ["m", "b"], unchanged: ["x", "y"])
        XCTAssertEqual(PbReloadResponse(diff).wire, diff)
    }

    func testEmptyStackDiffRoundTrip() {
        let diff = StackDiff(started: [], stopped: [], restarted: [], unchanged: [])
        XCTAssertEqual(PbReloadResponse(diff).wire, diff)
    }

    func testMetricsRoundTripPreservesOptionalProbeLatency() {
        let metrics = PodiumMetrics(
            stack: "demo", daemonUptimeSeconds: 12.5,
            services: [
                .init(id: "web", phase: "running", starts: 3, restarts: 2,
                      probeLatencySeconds: 0.004, relayConnections: 11),
                .init(id: "job", phase: "scheduled", starts: 0, restarts: 0,
                      probeLatencySeconds: nil, relayConnections: 0),
            ])
        XCTAssertEqual(PbMetricsResponse(metrics).wire(stack: "demo"), metrics)
    }
}
