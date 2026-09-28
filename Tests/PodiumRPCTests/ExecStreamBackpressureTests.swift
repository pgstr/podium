// ExecStreamBackpressureTests.swift — big-output regression + back-pressure guard.
import Foundation
import GRPCCore
import PodiumCore
import PodiumDaemon
import PodiumRPC
import XCTest

/// Emits `chunks` × `chunkSize` bytes of stdout through a *back-pressured*
/// sink (the real pipe-session shape) and exits 0 on its own. stdinEOF is a
/// no-op, like a real pipe session — output is self-driven.
final class BigExecSession: ExecSession, @unchecked Sendable {
    let output: ExecOutput
    private let sink: ExecOutputSink
    init(chunks: Int, chunkSize: Int, capacityBytes: Int) {
        (output, sink) = ExecOutput.makeBackpressured(capacityBytes: capacityBytes)
        let payload = Data(repeating: 0x7a, count: chunkSize)
        let s = sink
        Thread.detachNewThread {
            for _ in 0..<chunks { s.write(.stdout(payload)) }
            s.write(.exit(0)); s.finish()
        }
    }
    func writeStdin(_ data: Data) async {}
    func stdinEOF() async {}
    func resize(rows: UInt16, cols: UInt16) async {}
    func terminate() async { sink.finish() }
}

struct BigBackend: ControlPlaneBackend {
    let chunks: Int; let chunkSize: Int; let cap: Int
    private let stub = StubBackend()
    func snapshot() async -> [ServiceStatus] { await stub.snapshot() }
    func describe(_ id: String) async -> Reconciler.DescribeResult? { await stub.describe(id) }
    func stop(_ id: String) async -> Bool { await stub.stop(id) }
    func start(_ id: String) async -> Bool { await stub.start(id) }
    func restart(_ id: String) async -> Bool { await stub.restart(id) }
    func reloadFromDisk(dryRun: Bool) async throws -> StackDiff { try await stub.reloadFromDisk(dryRun: dryRun) }
    func stats() async -> [Reconciler.StatSample] { await stub.stats() }
    func events(after: Int) async -> [PodiumEvent] { await stub.events(after: after) }
    func eventStream(after: Int) async -> AsyncStream<PodiumEvent> { await stub.eventStream(after: after) }
    func logPath(_ id: String) async -> String? { await stub.logPath(id) }
    func importFile(_ id: String, hostPath: String, containerPath: String, mode: UInt32) async -> CopyOutcome {
        await stub.importFile(id, hostPath: hostPath, containerPath: containerPath, mode: mode)
    }
    func exportFile(_ id: String, containerPath: String, hostPath: String) async -> CopyOutcome {
        await stub.exportFile(id, containerPath: containerPath, hostPath: hostPath)
    }
    func recordAudit(action: AuditAction, serviceID: String?, user: String, argv: String) async {
        await stub.recordAudit(action: action, serviceID: serviceID, user: user, argv: argv)
    }
    func execSession(_ id: String, argv: [String], tty: Bool,
                     rows: UInt16, cols: UInt16) async throws -> (any ExecSession)? {
        guard id == "web" else { return nil }
        return BigExecSession(chunks: chunks, chunkSize: chunkSize, capacityBytes: cap)
    }
}

final class ExecStreamHangRepro: XCTestCase {
    private func tempSocketPath() -> String { "/tmp/podium-hang-\(UInt32.random(in: 0..<UInt32.max)).sock" }

    final class Received: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func add(_ c: Int) { lock.lock(); n += c; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// 256 MiB of stdout through a 4 MiB window streams end-to-end over the
    /// real HTTP/2-over-UDS transport, with the client half-closing stdin at
    /// once (the non-tty path). Every byte arrives, exit code is 0.
    func testBigOutputStreamsToCompletion() async throws {
        let chunks = 4096, chunkSize = 64 * 1024        // 256 MiB
        let backend = BigBackend(chunks: chunks, chunkSize: chunkSize, cap: 4 << 20)
        let service = PodiumControlService(
            daemonVersion: "hang-test-1", stackName: "sockstack", backend: backend)
        let path = tempSocketPath(); defer { unlink(path) }
        let listening = AsyncStream.makeStream(of: Void.self)
        let received = Received()

        try await withThrowingTaskGroup(of: Bool?.self) { group in
            group.addTask {
                try await ControlPlaneServer.serve(
                    socketPath: path, service: service,
                    onListening: { listening.continuation.yield(()) })
                return nil
            }
            group.addTask { try await Task.sleep(nanoseconds: 60 * 1_000_000_000); return false }  // watchdog
            group.addTask {
                for await _ in listening.stream { break }
                let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
                feed.yield(.eof); feed.finish()
                let exit = try await ControlPlaneClient.exec(
                    socketPath: path, service: "web", argv: ["big"],
                    tty: false, rows: 0, cols: 0, clientArgv: "podium exec web big",
                    input: input, onOutput: { out in
                        if case .stdout(let d) = out { received.add(d.count) }
                    })
                XCTAssertEqual(exit, 0)
                return true
            }
            while let r = try await group.next() {
                if let r { group.cancelAll(); XCTAssertTrue(r, "watchdog fired — the stream hung"); break }
            }
        }
        XCTAssertEqual(received.total, chunks * chunkSize, "all bytes must arrive")
    }

    /// The invariant that keeps the daemon alive: a fast producer feeding a
    /// slow consumer never lets unconsumed bytes exceed the window (plus at
    /// most one in-progress chunk). Before back-pressure this was unbounded
    /// and a big exec OOM'd the daemon.
    func testBackpressureBoundsInFlight() async throws {
        let cap = 256 * 1024, chunkSize = 16 * 1024, chunks = 2000   // ~31 MiB total
        let (output, sink) = ExecOutput.makeBackpressured(capacityBytes: cap)

        let pushed = ManagedAtomicIsh(); let consumed = ManagedAtomicIsh()
        let maxInFlight = ManagedAtomicIsh()

        Thread.detachNewThread {
            let payload = Data(repeating: 0x7a, count: chunkSize)
            for _ in 0..<chunks {
                sink.write(.stdout(payload))
                let p = pushed.add(chunkSize)
                maxInFlight.max(p - consumed.get())   // observed just after a write returns
            }
            sink.write(.exit(0)); sink.finish()
        }

        var total = 0
        for await chunk in output {
            if case .stdout(let d) = chunk {
                total += d.count
                consumed.add(d.count)
                try? await Task.sleep(nanoseconds: 300_000)   // deliberately slow reader
            }
        }
        XCTAssertEqual(total, chunks * chunkSize)
        // Producer can be at most cap + one chunk ahead of the consumer.
        XCTAssertLessThanOrEqual(maxInFlight.get(), cap + chunkSize,
                                 "producer outran the window — back-pressure is broken")
    }

    final class ManagedAtomicIsh: @unchecked Sendable {
        private let lock = NSLock(); private var v = 0
        @discardableResult func add(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; v += n; return v }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return v }
        func max(_ n: Int) { lock.lock(); if n > v { v = n }; lock.unlock() }
    }
}
