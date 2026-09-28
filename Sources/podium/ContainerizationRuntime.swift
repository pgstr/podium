// The apple/containerization adapter behind PodiumDaemon's `ContainerRuntime`
// seam: container create/boot, exec, statistics, log writers, port relays.
// Keeping these types out of the reconciler keeps it unit-testable.

import Containerization
import ContainerizationOS
import Darwin
import Foundation
import PodiumCore
import PodiumDaemon

/// Reference wrapper so the *mutating* `ContainerManager.create` doesn't live on
/// actor-isolated value state. The owning actor serializes all calls into it.
final class ManagerBox: @unchecked Sendable {
    private var m: ContainerManager
    init(_ m: ContainerManager) { self.m = m }
    func create(
        _ id: String, reference: String, rootfsSizeInBytes: UInt64,
        entrypoint: [String]?, command: [String]?, args: [String]?,
        configure: @escaping @Sendable (inout LinuxContainer.Configuration) -> Void
    ) async throws -> LinuxContainer {
        let image = try await m.imageStore.get(reference: reference, pull: true)
        let imageConfig = try await image.config(for: .current).config
        let hasProcessOverride = entrypoint != nil || command != nil || args != nil
        let resolvedArguments = hasProcessOverride ? ProcessArguments.resolve(
            imageEntrypoint: imageConfig?.entrypoint,
            imageCommand: imageConfig?.cmd,
            entrypoint: entrypoint, command: command, args: args) : nil
        return try await m.create(
            id, image: image, rootfsSizeInBytes: rootfsSizeInBytes
        ) { config in
            if let resolvedArguments { config.process.arguments = resolvedArguments }
            configure(&config)
        }
    }
    func delete(_ id: String) { try? m.delete(id) }
}

extension PortListener: PortRelayHandle {}

/// The real runtime: containers are Containerization `LinuxContainer` VMs.
final class ContainerizationRuntime: ContainerRuntime, @unchecked Sendable {
    private let box: ManagerBox

    init(manager: ContainerManager) {
        self.box = ManagerBox(manager)
    }

    func delete(_ id: String) { box.delete(id) }

    func createAndStart(_ config: RuntimeContainerConfig) async throws -> any RuntimeContainer {
        // Capture container stdout+stderr for `podium logs`. The handle owns
        // the writer and closes it when the container's wait() completes.
        let log = config.logPath.flatMap {
            try? FileLogWriter(path: $0, redactions: config.redactions)
        }
        let c = try await create(config, log: log)
        try await c.create()
        try await c.start()
        return CZContainer(container: c, log: log)
    }

    func runToCompletion(_ config: RuntimeContainerConfig) async throws -> Int32 {
        let c = try await create(config, log: nil)
        try await c.create()
        try await c.start()
        let st = try await c.wait()
        return Int32(truncatingIfNeeded: st.exitCode)
    }

    func startPortForwards(_ forwards: [PortForward], serviceID: String, ip: String)
        -> [any PortRelayHandle] {
        var listeners: [any PortRelayHandle] = []
        for pf in forwards {
            let listener = PortListener(hostPort: pf.hostPort, containerPort: pf.containerPort,
                                        bindAddress: pf.bindAddress)
            do {
                try listener.start(ip: ip)
                listeners.append(listener)
            } catch {
                print("[relay] \(serviceID): failed to bind :\(pf.hostPort) — \(error)")
            }
        }
        return listeners
    }

    private func create(_ config: RuntimeContainerConfig, log: FileLogWriter?) async throws -> LinuxContainer {
        let hosts = Hosts(
            entries: Hosts.default.entries
                + config.hostEntries.map { Hosts.Entry(ipAddress: $0.ip, hostnames: [$0.hostname]) },
            comment: "podium service discovery"
        )
        return try await box.create(
            config.id, reference: config.image, rootfsSizeInBytes: config.rootfsBytes,
            entrypoint: config.entrypoint, command: config.command, args: config.args
        ) { @Sendable cfg in
            cfg.cpus = config.cpus
            cfg.memoryInBytes = config.memoryBytes
            // Keep the image's ENTRYPOINT/CMD and WORKDIR unless the spec overrides them;
            // always append the spec/secret env on top of the image's env.
            if let wd = config.workingDirectory { cfg.process.workingDirectory = wd }
            cfg.process.environmentVariables += config.env
            if let log { cfg.process.stdout = log; cfg.process.stderr = log }
            for m in config.mounts {
                cfg.mounts.append(.share(source: m.source, destination: m.destination,
                                         options: m.readOnly ? ["ro"] : []))
            }
            // Inject peer service IPs so containers can reach each other by name.
            cfg.hosts = hosts
            if let dns = config.dns {
                cfg.dns = DNS(
                    nameservers: dns.nameservers,
                    searchDomains: dns.searchDomains,
                    options: dns.options)
            }
        }
    }
}

/// Live-container handle. Owns the service's log writer, closed exactly once
/// when the container exits (wait() returns).
final class CZContainer: RuntimeContainer, @unchecked Sendable {
    private let c: LinuxContainer
    private let log: FileLogWriter?
    private let logClosed = NSLock()
    private var didCloseLog = false

    init(container: LinuxContainer, log: FileLogWriter?) {
        self.c = container
        self.log = log
    }

    var ipAddress: String? {
        c.interfaces.first?.ipv4Address.address.description
    }

    func wait() async -> Int32 {
        let code = Int32(truncatingIfNeeded: (try? await c.wait())?.exitCode ?? -1)
        closeLogOnce()
        return code
    }

    func stop() async throws {
        defer { closeLogOnce() }
        try await c.stop()
    }

    func kill() async throws {
        try await c.kill(try Signal("SIGKILL"))
    }

    func exec(id: String, argv: [String]) async throws -> RuntimeExecResult {
        let out = BufferWriter(); let err = BufferWriter()
        let p = try await c.exec(id) { cfg in
            cfg.arguments = argv
            cfg.stdout = out
            cfg.stderr = err
        }
        try await p.start()
        let st = try await p.wait()
        try? await p.delete()
        return RuntimeExecResult(exitCode: Int32(truncatingIfNeeded: st.exitCode),
                                 stdout: out.data, stderr: err.data)
    }

    func statistics() async throws -> RuntimeStats {
        let st = try await c.statistics(categories: [.cpu, .memory])
        return RuntimeStats(cpuUsageUsec: st.cpu?.usageUsec,
                            memUsageBytes: st.memory?.usageBytes,
                            memLimitBytes: st.memory?.limitBytes)
    }

    // `cp` rides Containerization's native file transfer (dedicated vsock,
    // 1 MiB chunks, no shell, dir-aware). The control plane stages bytes in a
    // host file either side of this call, so the path arguments are ordinary
    // local files — quotes/spaces are irrelevant, nothing is interpolated.
    func importFile(hostPath: String, containerPath: String, mode: UInt32) async throws {
        try await c.copyIn(from: URL(fileURLWithPath: hostPath),
                           to: URL(fileURLWithPath: containerPath), mode: mode)
    }

    func exportFile(containerPath: String, hostPath: String) async throws {
        try await c.copyOut(from: URL(fileURLWithPath: containerPath),
                            to: URL(fileURLWithPath: hostPath))
    }

    private func closeLogOnce() {
        logClosed.lock(); defer { logClosed.unlock() }
        guard !didCloseLog else { return }
        didCloseLog = true
        try? log?.close()
    }

    // MARK: streaming exec sessions

    /// Non-tty: pipe-backed; stdout/stderr stream chunk-by-chunk, nothing
    /// accumulates daemon-side. tty: PTY-backed; a reader thread bridges the
    /// master fd, and resize is TIOCSWINSZ on the master.
    func startExecSession(id: String, argv: [String], tty: Bool,
                          rows: UInt16, cols: UInt16) async throws -> any ExecSession {
        tty ? try await startTTYSession(id: id, argv: argv, rows: rows, cols: cols)
            : try await startPipeSession(id: id, argv: argv)
    }

    /// Streams Data chunks straight into a sink as the framework writes them.
    private final class ChunkWriter: Writer, @unchecked Sendable {
        private let sink: @Sendable (Data) -> Void
        init(_ sink: @escaping @Sendable (Data) -> Void) { self.sink = sink }
        func write(_ d: Data) throws { if !d.isEmpty { sink(d) } }
        func close() throws {}
    }

    /// Exit code holder: the exit watcher records the code before it closes
    /// the PTY child, so the reader thread (which sees EOF after that close)
    /// always reads a settled value. Also gates terminate() to once.
    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32 = -1
        private var terminated = false
        func set(_ c: Int32) { lock.lock(); code = c; lock.unlock() }
        func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return code }
        func markFinished() { lock.lock(); terminated = true; lock.unlock() }
        func firstTerminate() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if terminated { return false }
            terminated = true; return true
        }
    }

    /// Unconsumed stdout/stderr the daemon holds before back-pressuring the
    /// container. 4 MiB keeps the vsock pipe full without bloat.
    private static let execBufferBytes = 4 << 20

    private func startPipeSession(id: String, argv: [String]) async throws -> any ExecSession {
        let (output, sink) = ExecOutput.makeBackpressured(capacityBytes: Self.execBufferBytes)
        let p = try await c.exec(id) { cfg in
            cfg.arguments = argv
            // sink.write blocks the framework's I/O thread when the window is
            // full → Containerization stops draining the guest → the process
            // blocks on write. Flat daemon memory, no data loss.
            cfg.stdout = ChunkWriter { sink.write(.stdout($0)) }
            cfg.stderr = ChunkWriter { sink.write(.stderr($0)) }
        }
        try await p.start()
        let box = ExitBox()
        Task {
            let st = try? await p.wait()
            box.markFinished()
            sink.write(.exit(st.map { Int32(truncatingIfNeeded: $0.exitCode) } ?? -1))
            sink.finish()
            try? await p.delete()
        }
        return ClosureExecSession(
            output: output,
            stdinWrite: { _ in },   // no stdin without a tty
            stdinClose: {},
            doResize: { _, _ in },
            doTerminate: {
                guard box.firstTerminate() else { return }
                sink.finish()              // unblock a stalled writer, end the stream
                do { try await p.kill(.kill) }
                catch { print("[exec] \(id): kill failed: \(error)") }
            })
    }

    private func startTTYSession(id: String, argv: [String],
                                 rows: UInt16, cols: UInt16) async throws -> any ExecSession {
        // Parent (master) stays here; child (slave) goes into the container.
        let (parent, child) = try Terminal.create(initialSize: .init(width: cols, height: rows))
        // Raw mode so the host ldisc doesn't buffer lines or eat Ctrl-C/Ctrl-D
        // before they reach the container.
        try? parent.setraw()
        let process = try await c.exec(id) { cfg in
            cfg.arguments = argv
            cfg.setTerminalIO(terminal: child)
        }
        try await process.start()

        let (output, sink) = ExecOutput.makeBackpressured(capacityBytes: Self.execBufferBytes)
        let parentFD = parent.handle.fileDescriptor
        let box = ExitBox()

        // Reader thread: PTY master → stdout chunks. It sees EOF only after
        // the exit watcher closes the child end, when the exit code is already
        // in the box — so .exit is always the last chunk. sink.write blocks this reader when
        // the window is full, back-pressuring the PTY.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(parentFD, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n < 0 {
                    let code = errno
                    print("[exec] \(id): PTY read failed: \(String(cString: strerror(code))) (errno \(code))")
                    break
                }
                if n == 0 { break }
                sink.write(.stdout(Data(buf[0..<n])))
            }
            sink.write(.exit(box.get()))
            sink.finish()
        }
        Task {
            let st = try? await process.wait()
            box.set(st.map { Int32(truncatingIfNeeded: $0.exitCode) } ?? -1)
            box.markFinished()
            try? child.close()      // EOF to the master → reader thread ends
            try? await process.delete()
        }

        return ClosureExecSession(
            output: output,
            stdinWrite: { d in
                d.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = Darwin.write(parentFD, base, d.count)
                }
            },
            stdinClose: {
                // PTY has no half-close; deliver EOT so line-reading shells
                // see EOF. Raw-mode clients normally end via typed Ctrl-D.
                var eot: UInt8 = 0x04
                _ = Darwin.write(parentFD, &eot, 1)
            },
            doResize: { r, cl in
                // The host PTY is only the vsock relay endpoint; changing its
                // winsize does not reach the guest PTY. vminitd owns the real
                // process terminal, so resize it through the runtime RPC.
                try? await process.resize(to: .init(width: cl, height: r))
            },
            doTerminate: { [parent] in
                guard box.firstTerminate() else { return }
                sink.finish()            // unblock the reader thread if it's stalled
                do { try await process.kill(.kill) }
                catch { print("[exec] \(id): kill failed: \(error)") }
                try? child.close()
                _ = parent   // keep the master alive for the session's lifetime
            })
    }
}

/// ExecSession over closures — lets pipe and PTY variants share one shell.
private final class ClosureExecSession: ExecSession, @unchecked Sendable {
    let output: ExecOutput
    private let stdinWrite: @Sendable (Data) -> Void
    private let stdinClose: @Sendable () -> Void
    private let doResize: @Sendable (UInt16, UInt16) async -> Void
    private let doTerminate: @Sendable () async -> Void

    init(output: ExecOutput,
         stdinWrite: @escaping @Sendable (Data) -> Void,
         stdinClose: @escaping @Sendable () -> Void,
         doResize: @escaping @Sendable (UInt16, UInt16) async -> Void,
         doTerminate: @escaping @Sendable () async -> Void) {
        self.output = output
        self.stdinWrite = stdinWrite
        self.stdinClose = stdinClose
        self.doResize = doResize
        self.doTerminate = doTerminate
    }

    func writeStdin(_ data: Data) async { stdinWrite(data) }
    func stdinEOF() async { stdinClose() }
    func resize(rows: UInt16, cols: UInt16) async { await doResize(rows, cols) }
    func terminate() async {
        // RPC cancellation propagates Task cancellation into the service
        // handler. Containerization's async kill RPC observes that flag and
        // otherwise cancels its own cleanup request. A detached task gives
        // teardown an uncancelled execution context; firstTerminate() inside
        // the closure keeps this idempotent across all competing paths.
        let terminate = doTerminate
        await Task.detached { await terminate() }.value
    }
}
