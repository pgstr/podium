// ControlPlaneServerTests.swift — the real unix socket:
// the daemon-side bootstrap serves GetInfo over canonical `podium.sock` semantics
// (0600 socket, stale-file replacement) and the peercred gate drops
// wrong-uid peers. Tests run as a single uid, so rejection is exercised by
// pointing the gate at a uid nobody has (expectedPeerUID override); the
// same-uid accept path and the fd-based helper cover the rest.

import XCTest
import GRPCCore
import PodiumRPC

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Platform shims: SOCK_STREAM is `__socket_type` on Glibc but already Int32
// on Darwin; and inside an XCTestCase, a bare `bind` resolves to NSObject's
// KVO instance method on macOS, so the C call needs module qualification.
#if canImport(Glibc)
private let sockStream = Int32(SOCK_STREAM.rawValue)
private func cBind(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    Glibc.bind(fd, sa, len)
}
#else
private let sockStream = SOCK_STREAM
private func cBind(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    Darwin.bind(fd, sa, len)
}
#endif

final class PeerCredentialsTests: XCTestCase {

    func testSocketpairPeerIsOurOwnUID() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, sockStream, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(try PeerCredentials.peerUID(of: fds[0]), getuid())
        XCTAssertEqual(try PeerCredentials.peerUID(of: fds[1]), getuid())
    }

    func testNonSocketFDThrows() {
        XCTAssertThrowsError(try PeerCredentials.peerUID(of: -1))
    }
}

final class ControlPlaneServerTests: XCTestCase {

    /// Short socket paths — a long HOME can push past sun_path.
    private func tempSocketPath() -> String {
        "/tmp/podium-t-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func serveAndDial<T: Sendable>(
        expectedPeerUID: uid_t = getuid(),
        _ body: @Sendable @escaping (String) async throws -> T
    ) async throws -> T {
        let path = tempSocketPath()
        defer { unlink(path) }
        let service = PodiumControlService(
            daemonVersion: "sock-test-1", stackName: "sockstack", backend: StubBackend())
        let listening = AsyncStream.makeStream(of: Void.self)
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await ControlPlaneServer.serve(
                    socketPath: path,
                    service: service,
                    expectedPeerUID: expectedPeerUID,
                    onListening: { listening.continuation.yield(()) }
                )
                return nil
            }
            group.addTask {
                for await _ in listening.stream { break }
                return try await body(path)
            }
            while let result = try await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            group.cancelAll()
            throw XCTSkip("unreachable: server task cannot return first")
        }
    }

    func testGetInfoOverUnixSocketAndSocketMode() async throws {
        let info = try await serveAndDial { path in
            // The socket inode is 0600 while the server is up.
            var st = stat()
            XCTAssertEqual(stat(path, &st), 0)
            XCTAssertEqual(st.st_mode & 0o777, 0o600, "v2 socket must be 0600")
            return try await ControlPlaneClient.getInfo(socketPath: path)
        }
        XCTAssertEqual(info.daemonVersion, "sock-test-1")
        XCTAssertEqual(info.protocolVersion, PodiumRPCVersion.protocolVersion)
        XCTAssertEqual(info.stackName, "sockstack")
        XCTAssertEqual(info.pid, getpid())  // in-process server: our own pid
    }

    func testStaleSocketFileIsReplaced() async throws {
        // A dead daemon leaves the inode behind; bind must still succeed.
        let info = try await serveAndDialWithStalePrep()
        XCTAssertEqual(info.stackName, "sockstack")
    }

    private func serveAndDialWithStalePrep() async throws -> PbInfoResponse {
        let path = tempSocketPath()
        defer { unlink(path) }
        // Plant a stale "socket": an orphaned bound socket with no listener.
        let stale = socket(AF_UNIX, sockStream, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            path.withCString { cPath in
                strncpy(UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self), cPath, 100)
            }
        }
        _ = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                cBind(stale, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)

        let service = PodiumControlService(
            daemonVersion: "sock-test-1", stackName: "sockstack", backend: StubBackend())
        let listening = AsyncStream.makeStream(of: Void.self)
        return try await withThrowingTaskGroup(of: PbInfoResponse?.self) { group in
            group.addTask {
                try await ControlPlaneServer.serve(
                    socketPath: path, service: service,
                    onListening: { listening.continuation.yield(()) })
                return nil
            }
            group.addTask {
                for await _ in listening.stream { break }
                return try await ControlPlaneClient.getInfo(socketPath: path)
            }
            while let result = try await group.next() {
                if let result { group.cancelAll(); return result }
            }
            group.cancelAll()
            throw XCTSkip("unreachable")
        }
    }

    func testWrongUIDPeerIsRejected() async throws {
        // Point the gate at a uid we do not have: our own connect() must be
        // dropped before any RPC completes. (Real second-uid coverage is the
        // Mac selftest's job; this proves the gate is wired and fails closed.)
        do {
            let info = try await serveAndDial(expectedPeerUID: getuid() &+ 1) { path in
                try await ControlPlaneClient.getInfo(socketPath: path)
            }
            XCTFail("GetInfo should not succeed through the peercred gate, got \(info)")
        } catch {
            // Expected: the connection is closed by the server; the client
            // surfaces a transport-level failure (exact error shape is the
            // transport's business — asserting on success/failure only).
        }
    }
}
