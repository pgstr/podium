// PodiumControlServiceTests.swift — `GetInfo` returns the version
// handshake, and every not-yet-migrated RPC fails with UNIMPLEMENTED (not a
// hang, not INTERNAL). Runs the real GRPCServer over the in-process
// transport, so this covers the generated glue without touching a unix
// socket (the socket + peercred path is ControlPlaneServerTests + selftest).

import XCTest
import GRPCCore
import GRPCInProcessTransport
import PodiumCore
import PodiumDaemon
import PodiumRPC

final class PodiumControlServiceTests: XCTestCase {

    /// Runs `body` against a live in-process server hosting the service.
    private func withService<T: Sendable>(
        backend: StubBackend = StubBackend(),
        _ body: @Sendable @escaping (PbPodiumControl.Client<InProcessTransport.Client>) async throws -> T
    ) async throws -> T {
        let transport = InProcessTransport()
        let service = PodiumControlService(
            daemonVersion: "test-daemon-9.9.9", stackName: "teststack", backend: backend)
        let server = GRPCServer(transport: transport.server, services: [service])
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let result: T
            do {
                let client = GRPCClient(transport: transport.client)
                group.addTask { try await client.runConnections() }
                result = try await body(PbPodiumControl.Client(wrapping: client))
                client.beginGracefulShutdown()
            } catch {
                server.beginGracefulShutdown()
                group.cancelAll()
                throw error
            }
            server.beginGracefulShutdown()
            group.cancelAll()
            return result
        }
    }

    func testGetInfoReturnsVersionHandshake() async throws {
        let info = try await withService { client in
            try await client.getInfo(PbInfoRequest())
        }
        XCTAssertEqual(info.daemonVersion, "test-daemon-9.9.9")
        XCTAssertEqual(info.protocolVersion, PodiumRPCVersion.protocolVersion)
        XCTAssertEqual(info.stackName, "teststack")
        XCTAssertGreaterThan(info.pid, 0)
    }

    func testLifecycleGatedRPCReturnsUnimplemented() async throws {
        // Down is lifecycle-gated: without the daemon's onDown wiring it must
        // surface UNIMPLEMENTED with an actionable pointer, proving the stub is
        // wired through the generated glue rather than dropped.
        try await withService { client in
            do {
                var req = PbDownRequest()
                req.deleteVolumes = false
                _ = try await client.down(req)
                XCTFail("Down should be UNIMPLEMENTED without the daemon's onDown wiring (E3.5)")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .unimplemented)
                XCTAssertTrue(error.message.contains("daemon lifecycle wiring"),
                              "error should say what's missing: \(error.message)")
            }
        }
    }

    // MARK: unary verbs

    func testListServicesReturnsSnapshot() async throws {
        let ps = try await withService { client in
            try await client.listServices(PbEmpty())
        }
        XCTAssertEqual(ps.stack, "teststack")   // service's stack name, not the backend's
        XCTAssertEqual(ps.services.map(\.id), ["web", "cron-job"])
        let web = ps.services[0].wire
        XCTAssertEqual(web.state, "running")
        XCTAssertEqual(web.ip, "192.168.64.5")
        XCTAssertEqual(web.portForwards, [PortForward(host: 8080, container: 80)])
        let cron = ps.services[1].wire
        XCTAssertEqual(cron.schedule, "0 2 * * *")
        XCTAssertEqual(cron.lastExit, 0)        // exit 0 must survive the wire
    }

    func testDescribeKnownAndUnknown() async throws {
        try await withService { client in
            var ref = PbServiceRef()
            ref.id = "web"
            let d = try await client.describe(ref).wire(stack: "teststack")
            XCTAssertEqual(d.image, "nginx:1.27")
            XCTAssertEqual(d.env, ["FOO": "bar"])
            XCTAssertEqual(d.healthCheck, ["curl", "-f", "http://localhost/"])
            XCTAssertNil(d.failReason)

            var missing = PbServiceRef()
            missing.id = "ghost"
            do {
                _ = try await client.describe(missing)
                XCTFail("describe(ghost) should be NOT_FOUND")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .notFound)
                XCTAssertEqual(error.message, "unknown service")   // the CLI prints this verbatim
            }
        }
    }

    func testControlActions() async throws {
        try await withService { client in
            for action in [PbControlRequest.Action.stop, .start, .restart] {
                var req = PbControlRequest()
                req.service.id = "web"
                req.action = action
                let resp = try await client.control(req)
                XCTAssertTrue(resp.ok, "\(action) web should succeed")
            }
            var req = PbControlRequest()
            req.service.id = "ghost"
            req.action = .stop
            let resp = try await client.control(req)
            XCTAssertFalse(resp.ok)
            XCTAssertEqual(resp.error, "unknown service")

            var bad = PbControlRequest()
            bad.service.id = "web"   // action left UNSPECIFIED
            do {
                _ = try await client.control(bad)
                XCTFail("unspecified action should be INVALID_ARGUMENT")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .invalidArgument)
            }
        }
    }

    func testReloadAndDiff() async throws {
        try await withService { client in
            var dry = PbReloadRequest()
            dry.dryRun = true
            let diff = try await client.reload(dry).wire
            XCTAssertEqual(diff.restarted, ["web"])
            XCTAssertEqual(diff.started, [])

            let real = try await client.reload(PbReloadRequest()).wire
            XCTAssertEqual(real.started, ["new-svc"])
            XCTAssertEqual(real.unchanged, ["web", "cron-job"])
        }
    }

    func testMutatingRPCsRecordAuditMetadataButDiffDoesNot() async throws {
        let backend = StubBackend()
        try await withService(backend: backend) { client in
            var stop = PbControlRequest()
            stop.service.id = "web"
            stop.action = .stop
            stop.client.user = "alice"
            stop.client.argv = "podium stop web"
            _ = try await client.control(stop)

            var dry = PbReloadRequest()
            dry.dryRun = true
            dry.client.user = "alice"
            dry.client.argv = "podium diff"
            _ = try await client.reload(dry)

            var reload = PbReloadRequest()
            reload.client.user = "alice"
            reload.client.argv = "podium reload"
            _ = try await client.reload(reload)
        }
        XCTAssertEqual(backend.auditLog.all, [
            .init(action: .stop, serviceID: "web", user: "alice", argv: "podium stop web"),
            .init(action: .reload, serviceID: nil, user: "alice", argv: "podium reload"),
        ])
    }

    func testReloadFailureCarriesErrorText() async throws {
        try await withService(backend: StubBackend(failReload: true)) { client in
            do {
                _ = try await client.reload(PbReloadRequest())
                XCTFail("broken stack should fail reload")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .internalError)
                // CLI prints "podium: <message>" with the thrown error's description.
                XCTAssertEqual(error.message, "stack file is broken")
            }
        }
    }
}
