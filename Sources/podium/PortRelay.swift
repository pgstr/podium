import Darwin
import Foundation

/// Manages a host-side TCP listener that forwards accepted connections to a container IP:port.
///
/// Lifecycle: `init` → `start(ip:)` → optionally `updateIP(_:)` on container restart → `stop()`.
///
/// Each accepted connection is handed to macOS `nc` so the upstream socket lives outside
/// the VM-owning process (whose VM bridge route is interface-scoped).
/// Stopping the listener closes the listen socket, which unblocks any pending `accept(2)`,
/// ending the accept loop. In-flight relay connections drain naturally.
final class PortListener: @unchecked Sendable {
    let hostPort: Int
    let containerPort: Int
    /// Host-side address to bind — loopback by default, "0.0.0.0" to publish.
    let bindAddress: String

    private var targetIP: String = ""
    private var listenFD: Int32 = -1
    private var acceptedConnections: UInt64 = 0
    private var activeRelays: [UUID: Process] = [:]
    private let lock = NSLock()

    init(hostPort: Int, containerPort: Int, bindAddress: String = "127.0.0.1") {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.bindAddress = bindAddress
    }

    deinit { stop() }

    // MARK: - Public interface

    func start(ip: String) throws {
        lock.withLock { targetIP = ip }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }

        // Allow rapid rebind after a restart.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(hostPort).bigEndian
        guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }

        let bindRC = withUnsafeBytes(of: &addr) {
            Darwin.bind(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                        socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bindRC == 0 else { Darwin.close(fd); throw posixError() }
        guard Darwin.listen(fd, 32) == 0 else { Darwin.close(fd); throw posixError() }

        lock.withLock { listenFD = fd }
        print("[relay] \(bindAddress):\(hostPort) → \(ip):\(containerPort) — listening")

        let t = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        t.name = "podium-relay-\(hostPort)"
        t.qualityOfService = .utility
        t.start()
    }

    /// Call when the container restarts with a new IP. New connections will use the updated IP.
    func updateIP(_ ip: String) {
        lock.withLock { targetIP = ip }
        print("[relay] :\(hostPort) → \(ip):\(containerPort) — target IP updated")
    }

    var connectionCount: UInt64 { lock.withLock { acceptedConnections } }
    var canRetarget: Bool { true }

    func retarget(ip: String) -> Bool {
        updateIP(ip)
        return true
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let f = listenFD; listenFD = -1; return f
        }
        if fd >= 0 {
            Darwin.close(fd)  // unblocks any pending accept(2)
            print("[relay] :\(hostPort) — stopped")
        }
    }

    // MARK: - Accept loop (runs on background thread)

    private func acceptLoop(fd: Int32) {
        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                // EBADF / EINVAL → listen socket was closed via stop(); normal shutdown.
                break
            }
            let ip = lock.withLock { targetIP }
            guard !ip.isEmpty else { Darwin.close(clientFD); continue }
            lock.withLock { acceptedConnections &+= 1 }

            do {
                try launchRelay(clientFD: clientFD, ip: ip)
            } catch {
                print("[relay] :\(hostPort) → \(ip):\(containerPort) — connection failed: \(error)")
                Darwin.close(clientFD)
            }
        }
    }

    // MARK: - Helpers

    private func launchRelay(clientFD: Int32, ip: String) throws {
        let token = UUID()
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        relay.arguments = ["-G", "5", ip, String(containerPort)]
        relay.standardInput = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
        relay.standardOutput = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
        relay.standardError = FileHandle.nullDevice
        relay.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.activeRelays.removeValue(forKey: token) }
        }

        lock.withLock { activeRelays[token] = relay }
        do {
            try relay.run()
            Darwin.close(clientFD)
        } catch {
            lock.withLock { _ = activeRelays.removeValue(forKey: token) }
            throw error
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
}
