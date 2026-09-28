// podium — a native single-host container orchestrator for Apple silicon,
// built on apple/containerization. Run `podium --help` for commands.
// Expects a Linux kernel at ~/.podium/vmlinux (see `make runtime-assets`).

import Containerization
import ContainerizationArchive
import ContainerizationOS
import Darwin
import Foundation
import PodiumCore
import PodiumDaemon
import PodiumRPC

// Unbuffered stdout so logs reach launchd's StandardOutPath (a file, not a tty)
// immediately instead of sitting in a block buffer until exit/crash.
setvbuf(stdout, nil, _IONBF, 0)

/// Build label reported in the GetInfo handshake; clients key on `protocolVersion`.
let podiumDaemonVersion = "0.9.0"

/// Must match Package.swift's exact apple/containerization pin. The host
/// library and vminit guest agent share an RPC surface and are upgraded as one.
private let containerizationVersion = "0.46.0"
private let vminitVersion = containerizationVersion

private func vminitPath(store: ImageStore) -> URL {
    store.path.appendingPathComponent("initfs-vminit-\(vminitVersion).ext4")
}

private func resolvedKernelPath() -> String {
    if let path = ProcessInfo.processInfo.environment["PODIUM_KERNEL"], !path.isEmpty {
        return path
    }
    let installed = (NSHomeDirectory() as NSString).appendingPathComponent(".podium/vmlinux")
    if FileManager.default.fileExists(atPath: installed) { return installed }
    return "./vmlinux"
}

private struct ToolResult {
    let status: Int32
    let output: String
}

private func runTool(_ executable: String, _ arguments: [String]) -> ToolResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(status: process.terminationStatus, output: output)
    } catch {
        return ToolResult(status: 127, output: String(describing: error))
    }
}

private func directoryBytes(_ path: String) -> UInt64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants]) else { return 0 }
    var total: UInt64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true else { continue }
        total &+= UInt64(max(0, values.fileSize ?? 0))
    }
    return total
}

private func fileBytes(_ path: String) -> UInt64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber else { return 0 }
    return size.uint64Value
}

private func humanBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
    return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
}

/// Build or reuse the init filesystem for exactly the version Podium links
/// against. ContainerManager's `initfsReference` initializer always caches at
/// one unversioned `initfs.ext4` path, so changing the reference can silently
/// keep booting an older guest agent. A cross-process lock also prevents two
/// stack daemons from observing a partially unpacked image on first launch.
private func versionedInitfs(store: ImageStore) async throws -> Containerization.Mount {
    let reference = "ghcr.io/apple/containerization/vminit:\(vminitVersion)"
    let path = vminitPath(store: store)
    let readyPath = path.appendingPathExtension("ready")
    let lockPath = path.appendingPathExtension("lock")
    let lockFD = open(lockPath.path, O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    if FileManager.default.fileExists(atPath: path.path),
       FileManager.default.fileExists(atPath: readyPath.path) {
        return Containerization.Mount.block(
            format: "ext4", source: path.path, destination: "/", options: ["ro"])
    }

    // A file without its ready marker is residue from an interrupted unpack.
    try? FileManager.default.removeItem(at: path)
    try? FileManager.default.removeItem(at: readyPath)
    do {
        let image = try await store.getInitImage(reference: reference)
        let mount = try await image.initBlock(at: path, for: .linuxArm)
        try reference.write(to: readyPath, atomically: true, encoding: .utf8)
        return mount
    } catch {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: readyPath)
        throw error
    }
}

func makeManager(kernelPath: String) async throws -> ContainerManager {
    guard FileManager.default.fileExists(atPath: kernelPath) else {
        FileHandle.standardError.write(Data(
            "podium: kernel not found at \(kernelPath) — run `make kernel` (or set PODIUM_KERNEL)\n".utf8))
        Foundation.exit(1)
    }
    let store = ImageStore.default
    let initfs = try await versionedInitfs(store: store)
    return try ContainerManager(
        kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
        initfs: initfs,
        imageStore: store,
        network: try VmnetNetwork()
    )
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage:
          podium apply    <stack.json|compose.yml>         bring a stack up (daemon)
          podium selftest <stack.json>                     run reconciler assertions, exit 0/1
          podium validate <stack.json|compose.yml>         check a stack file without starting VMs
          podium migrate  <compose.yml>                    print equivalent native stack.json to stdout
          podium stacks   [--prune]                        list stacks; prune dead sockets safely
          podium doctor                                    host/runtime diagnostics with remediation
          podium ps       [--stack <name>]                 show service status
          podium top      [--stack <name>] [--host <user@host>] [--once] [--interval <dur>]   live CPU%/memory table
          podium metrics  [--stack <name>] [--host <user@host>] Prometheus text snapshot
          podium tui      [--stack <name>] [--host <user@host>] interactive service dashboard
          podium logs     [--stack <name>] [--host <user@host>] [--previous] [--tail N] [--since <dur>] <svc> [-f]
          podium stop|start|restart [--stack <name>] [--host <user@host>] <svc>
          podium diff     [--stack <name>] [--host <user@host>]   preview what reload would change
          podium reload   [--stack <name>] [--host <user@host>]
          podium describe [--stack <name>] [--host <user@host>] <svc>
          podium exec     [--stack <name>] [--host <user@host>] [-it] <svc> <cmd...>
          podium cp       [--stack <name>] [--host <user@host>] <svc>:<path> <local>
          podium cp       [--stack <name>] [--host <user@host>] <local> <svc>:<path>
          podium events   [--stack <name>] [--host <user@host>] [-f]
          podium down     [--stack <name>] [--host <user@host>] [--volumes] [-y]
          (--host tunnels the control socket over SSH to a remote daemon)
          podium images                                    list images in local store
          podium pull     <ref> [--as <alias>] [--insecure] pull an image (HTTPS by default)
          podium load     <image.tar>                      import OCI tar (from docker/container save)
          podium prepare-runtime                           pre-cache the versioned vminit filesystem\n
        """.utf8))
    Foundation.exit(2)
}

// Strip `--stack <name>` from `args` and return (stackName, remaining).
func parseStack(_ args: [String]) -> (stackName: String?, rest: [String]) {
    var rest = args
    if let i = rest.firstIndex(of: "--stack"), i + 1 < rest.count {
        let name = rest[i + 1]; rest.remove(at: i + 1); rest.remove(at: i)
        return (name, rest)
    }
    return (nil, rest)
}

// Resolve socket path for a client command; exit with a helpful message on failure.
// If `host` is provided, establishes an SSH tunnel and returns the local end's path.
func requireSocket(_ stackName: String?, host: String? = nil) -> String {
    if let host { return setupSSHTunnel(host: host, stackName: stackName) }
    if let p = Control.resolve(stackName: stackName) { return p }
    let live = Control.activeStacks()
    if live.isEmpty {
        FileHandle.standardError.write(Data("podium: no running stacks in \(Control.podiumRoot)\n".utf8))
    } else {
        let names = live.map { $0.name }.joined(separator: ", ")
        FileHandle.standardError.write(Data(
            "podium: multiple stacks running (\(names)) — use --stack <name>\n".utf8))
    }
    Foundation.exit(1)
}

// Strip `--host <user@host>` from `args` and return (host, remaining).
func parseHost(_ args: [String]) -> (host: String?, rest: [String]) {
    var rest = args
    if let i = rest.firstIndex(of: "--host"), i + 1 < rest.count {
        let h = rest[i + 1]; rest.remove(at: i + 1); rest.remove(at: i)
        return (h, rest)
    }
    return (nil, rest)
}

// SSH tunnel state, torn down via atexit_b. nonisolated(unsafe) because
// top-level vars are @MainActor under Swift 6 but atexit_b is nonisolated;
// process exit is single-threaded.
private nonisolated(unsafe) var _tunnelProcess: Process? = nil
private nonisolated(unsafe) var _tunnelSocketPath: String? = nil

private func teardownTunnel() {
    _tunnelProcess?.terminate(); _tunnelProcess = nil
    if let p = _tunnelSocketPath {
        try? FileManager.default.removeItem(atPath: p)
        _tunnelSocketPath = nil
    }
}

/// SSH multiplexing options shared by every ssh spawned for `host`, so they
/// ride one authenticated master. ControlPersist keeps it alive between
/// `podium` invocations, making later commands cheap.
private func sshMuxArgs(host: String) -> [String] {
    let home = NSHomeDirectory()
    try? FileManager.default.createDirectory(
        atPath: SSHTunnelPaths.dir(home: home),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return ["-o", "ControlMaster=auto",
            "-o", "ControlPath=\(SSHTunnelPaths.controlPath(home: home, host: host))",
            "-o", "ControlPersist=120",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5"]
}

/// Ensure the persistent connection exists before a per-command `-L`
/// forwarder is launched. Without this, a cache hit plus a cold master makes
/// the forwarder itself become the ControlPersist master, so its temporary
/// local forwards survive after the podium command exits.
private func ensureSSHMaster(host: String) {
    func run(_ tail: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshMuxArgs(host: host) + tail
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    let controlPath = SSHTunnelPaths.controlPath(home: NSHomeDirectory(), host: host)
    // A live ControlPersist master owns this socket and removes it when its
    // timer expires. Skip `ssh -O check` on warm runs; that round-trip would
    // dominate their latency.
    if FileManager.default.fileExists(atPath: controlPath) { return }
    if run(SSHTunnelPaths.masterStartArguments(host: host)) == 0 { return }
    // A concurrent Podium invocation may have won the start race. Verify only
    // on that cold-path failure; a stale socket must not be mistaken for live.
    guard run(SSHTunnelPaths.masterCheckArguments(host: host)) == 0 else {
        FileHandle.standardError.write(Data(
            "podium: SSH to '\(host)' failed — check connectivity and SSH keys\n".utf8))
        Foundation.exit(1)
    }
}

/// The remote user's `$HOME`, cached per host so warm runs skip the probe SSH.
/// A miss probes once over the (now-open) master — cheap — and writes the cache.
private func remoteHome(host: String) -> String {
    ensureSSHMaster(host: host)
    let cachePath = SSHTunnelPaths.homeCache(home: NSHomeDirectory(), host: host)
    if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8) {
        let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    let homeProc = Process()
    homeProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    homeProc.arguments = sshMuxArgs(host: host)
        + SSHTunnelPaths.remoteHomeProbeArguments(host: host)
    let homePipe = Pipe()
    homeProc.standardOutput = homePipe; homeProc.standardError = Pipe()
    guard (try? homeProc.run()) != nil else {
        FileHandle.standardError.write(Data("podium: SSH to '\(host)' failed\n".utf8)); Foundation.exit(1)
    }
    homeProc.waitUntilExit()
    guard homeProc.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("podium: SSH to '\(host)' failed — check connectivity and SSH keys\n".utf8))
        Foundation.exit(1)
    }
    let home = String(data: homePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !home.isEmpty else {
        FileHandle.standardError.write(Data("podium: could not determine home directory on '\(host)'\n".utf8))
        Foundation.exit(1)
    }
    try? home.write(toFile: cachePath, atomically: true, encoding: .utf8)
    return home
}

/// Establish an SSH Unix-socket tunnel to `host` and return its local endpoint.
/// The forwarder reuses the persisted master, so a warm command performs no
/// additional SSH handshake. Requires --stack.
private func setupSSHTunnel(host: String, stackName: String?) -> String {
    guard let sName = stackName else {
        FileHandle.standardError.write(Data("podium: --host requires --stack <name>\n".utf8))
        Foundation.exit(1)
    }
    let home = remoteHome(host: host)
    let remote = "\(home)/.podium/\(sName)/podium.sock"
    let local = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("podium-\(UUID().uuidString).sock")

    // One forwarding channel over the shared master. The temporary socket is
    // removed at exit; the master persists for the next command.
    let ssh = Process()
    ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    ssh.arguments = sshMuxArgs(host: host)
        + ["-NT", "-o", "ExitOnForwardFailure=yes",
           "-L", "\(local):\(remote)", host]
    ssh.standardError = Pipe()
    guard (try? ssh.run()) != nil else {
        FileHandle.standardError.write(Data("podium: failed to start SSH tunnel\n".utf8)); Foundation.exit(1)
    }
    _tunnelProcess = ssh; _tunnelSocketPath = local
    atexit_b { teardownTunnel() }

    // Wait up to 5 s for the local socket to appear.
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: local) {
        guard ssh.isRunning, Date() < deadline else {
            teardownTunnel()
            FileHandle.standardError.write(Data(
                "podium: tunnel timed out — is podium running on '\(host)' with --stack \(sName)?\n".utf8))
            Foundation.exit(1)
        }
        // A warm multiplexed tunnel opens in a few milliseconds; poll finely.
        Thread.sleep(forTimeInterval: 0.01)
    }
    print("[podium] tunnel: \(host) → \(local)")
    return local
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 1 else { usage() }
let command = args[0]

// `doctor` is host-local and never needs a running stack.
if command == "doctor" {
    var checks: [DoctorCheck] = []
    let kernel = resolvedKernelPath()
    if FileManager.default.isReadableFile(atPath: kernel) {
        checks.append(.init(name: "kernel", status: .pass, detail: kernel))
    } else {
        checks.append(.init(
            name: "kernel", status: .fail, detail: "missing at \(kernel)",
            remediation: "run `make kernel` or set PODIUM_KERNEL"))
    }

    let containerVersion = runTool("/usr/bin/env", ["container", "system", "version"])
    if containerVersion.status == 0, !containerVersion.output.isEmpty {
        let oneLine = containerVersion.output.split(whereSeparator: \.isNewline)
            .joined(separator: "; ")
        checks.append(.init(name: "container tool", status: .pass, detail: oneLine))
    } else {
        checks.append(.init(
            name: "container tool", status: .warning,
            detail: "not available on PATH (optional after kernel installation)",
            remediation: "install Apple container when refreshing the kernel"))
    }

    let store = ImageStore.default
    let initfs = vminitPath(store: store)
    let ready = initfs.appendingPathExtension("ready")
    let expectedReference = "ghcr.io/apple/containerization/vminit:\(vminitVersion)"
    let marker = try? String(contentsOf: ready, encoding: .utf8)
    if FileManager.default.isReadableFile(atPath: initfs.path), marker == expectedReference {
        checks.append(.init(name: "vminit", status: .pass,
                            detail: "\(vminitVersion) cached at \(initfs.path)"))
    } else {
        checks.append(.init(
            name: "vminit", status: .fail,
            detail: "matching \(vminitVersion) cache or ready marker is missing",
            remediation: "run `podium prepare-runtime` while online"))
    }

    let stale = Control.staleStacks()
    if stale.isEmpty {
        checks.append(.init(name: "stack locks/sockets", status: .pass,
                            detail: "no stale control sockets"))
    } else {
        checks.append(.init(
            name: "stack locks/sockets", status: .fail,
            detail: "stale: \(stale.joined(separator: ", "))",
            remediation: "run `podium stacks --prune` (durable data is preserved)"))
    }

    let binary = DoctorExecutablePath.resolve(argv0: CommandLine.arguments[0])
    let signature = runTool("/usr/bin/codesign", ["--verify", "--strict", binary])
    if signature.status == 0 {
        let detail = runTool("/usr/bin/codesign", ["-dv", "--verbose=4", binary]).output
        let identity = detail.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Authority=") || $0.hasPrefix("Signature=") }
            .map(String.init) ?? "valid code signature"
        checks.append(.init(name: "signing", status: .pass, detail: identity))
    } else {
        checks.append(.init(name: "signing", status: .fail,
                            detail: signature.output.isEmpty ? "invalid signature" : signature.output,
                            remediation: "run `make build` and use the freshly signed binary"))
    }

    let root = StackPaths.podiumRoot
    // Count by named subdirectories so volumes and logs remain separately actionable.
    var logBytes: UInt64 = 0
    var volumeBytes: UInt64 = 0
    if let stacks = try? FileManager.default.contentsOfDirectory(atPath: root) {
        for stack in stacks {
            let dir = (root as NSString).appendingPathComponent(stack)
            logBytes &+= directoryBytes((dir as NSString).appendingPathComponent("logs"))
            let daemonLog = (dir as NSString).appendingPathComponent("daemon.log")
            logBytes &+= fileBytes(daemonLog)
            volumeBytes &+= directoryBytes((dir as NSString).appendingPathComponent("volumes"))
        }
    }
    checks.append(.init(name: "disk usage", status: .pass,
                        detail: "logs \(humanBytes(logBytes)); volumes \(humanBytes(volumeBytes))"))

    let report = DoctorReport(checks: checks)
    print(report.rendered())
    Foundation.exit(report.hasFailures ? 1 : 0)
}

// `pull` is image management only — no stack, kernel, or VM needed. HTTPS is the
// secure default; local plaintext registries require an explicit `--insecure`.
// After this the image is cached locally and `apply` resolves it without touching
// the registry (get is pull-if-absent).
if command == "pull" {
    guard args.count >= 2 else { usage() }
    let ref = args[1]
    let insecure = args.contains("--insecure")
    let store = ImageStore.default
    print("[podium] pulling \(ref) (\(insecure ? "insecure HTTP" : "HTTPS")) …")
    let img = try await store.pull(reference: ref, insecure: insecure)
    print("[podium] pulled \(img.reference)")
    if let i = args.firstIndex(of: "--as"), i + 1 < args.count {
        _ = try await store.tag(existing: ref, new: args[i + 1])
        print("[podium] tagged → \(args[i + 1])")
    }
    Foundation.exit(0)
}

// `images` — list all images in podium's local store.
if command == "images" {
    let store = ImageStore.default
    let images = try await store.list()
    if images.isEmpty { print("(no images in store)"); Foundation.exit(0) }
    let refW = max(images.map { $0.reference.count }.max() ?? 0, 9)
    print("REFERENCE".padding(toLength: refW, withPad: " ", startingAt: 0) + "  DIGEST")
    for img in images.sorted(by: { $0.reference < $1.reference }) {
        let ref = img.reference.padding(toLength: refW, withPad: " ", startingAt: 0)
        let digest = String(img.descriptor.digest.prefix(19))
        print("\(ref)  \(digest)")
    }
    Foundation.exit(0)
}

// `load` imports an OCI tar (`container image save …`) straight into the
// library store, without a registry.
if command == "load" {
    guard args.count >= 2 else { usage() }
    let store = ImageStore.default
    let reader = try ArchiveReader(file: URL(fileURLWithPath: args[1]).absoluteURL)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("podium-load-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    _ = try reader.extractContents(to: tmp)
    let imported = try await store.load(from: tmp)
    for img in imported { print("[podium] loaded \(img.reference)") }
    Foundation.exit(0)
}

// Installation-time runtime preparation. This materializes the exact
// vminit guest that matches the linked Containerization library. Subsequent
// daemon cold starts take the ready-marker fast path without registry access.
if command == "prepare-runtime" {
    let store = ImageStore.default
    do {
        _ = try await versionedInitfs(store: store)
        print("vminit \(vminitVersion) ready -> \(vminitPath(store: store).path)")
        Foundation.exit(0)
    } catch {
        FileHandle.standardError.write(Data(
            "podium: could not prepare vminit \(vminitVersion): \(error)\n".utf8))
        Foundation.exit(1)
    }
}

// `migrate <compose.yml>` — translate a compose file to native stack.json and print to stdout.
if command == "migrate" {
    let path = args.count >= 2 ? args[1] : "docker-compose.yml"
    do {
        let stack = try Stack.load(path)
        try stack.validate()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try enc.encode(stack), encoding: .utf8)!)
    } catch {
        FileHandle.standardError.write(Data("podium: \(error)\n".utf8))
        Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `validate <stack.json>` — parse and validate a stack file; no VM or daemon needed.
if command == "validate" {
    let path = args.count >= 2 ? args[1] : "./stack.json"
    do {
        let s = try Stack.load(path)
        try s.validate()
        print("ok  \(s.name) (\(s.services.count) service(s): \(s.services.map { $0.id }.joined(separator: ", ")))")
    } catch {
        FileHandle.standardError.write(Data("podium: \(error)\n".utf8))
        Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `down [--stack <name>] [--volumes] [-y]` — gracefully stop a running daemon.
// --volumes also deletes all managed volume data for the stack (destructive; prompts unless -y).
if command == "down" {
    var downArgs = Array(args.dropFirst())
    let deleteVolumes = downArgs.contains("--volumes"); downArgs.removeAll { $0 == "--volumes" }
    let skipConfirm   = downArgs.contains("-y") || downArgs.contains("--yes")
    downArgs.removeAll { $0 == "-y" || $0 == "--yes" }
    let (stackName, r0) = parseStack(downArgs)
    let (host, _) = parseHost(r0)

    // The stack name is needed for the volume path; derive it from the socket
    // (~/.podium/<name>/podium.sock) when --stack was not given.
    let sock = requireSocket(stackName, host: host)
    let resolvedName: String = stackName ?? {
        let components = (sock as NSString).pathComponents
        let sockIdx = components.lastIndex(of: "podium.sock") ?? components.endIndex
        return sockIdx > 0 ? components[sockIdx - 1] : sock
    }()

    // Volume deletion runs daemon-side after every container stops. Confirm
    // before the request because a successful response begins shutdown.
    if deleteVolumes && !skipConfirm {
        let localRoot = host == nil ? StackPaths.volumesRoot(for: resolvedName) : nil
        let shouldPrompt = host != nil || (localRoot.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        if shouldPrompt {
            if let r = localRoot {
                print("This permanently deletes all managed volume data for '\(resolvedName)' at")
                print("  \(r)")
            } else {
                print("This permanently deletes all managed volume data for '\(resolvedName)' on \(host!).")
            }
            print("Continue? [y/N] ", terminator: ""); fflush(stdout)
            let answer = readLine() ?? ""
            guard answer.lowercased().hasPrefix("y") else { print("aborted"); Foundation.exit(0) }
        }
    }
    do {
        let resp = try await ControlPlaneClient.down(
            socketPath: sock, deleteVolumes: deleteVolumes,
            argv: CommandLine.arguments.joined(separator: " "))
        guard resp.ok else {
            FileHandle.standardError.write(Data("podium: down refused\n".utf8)); Foundation.exit(1)
        }
        print("down: accepted — waiting for shutdown")
        if host == nil {
            let deadline = Date().addingTimeInterval(60)
            while Control.lockIsHeld(for: resolvedName), Date() < deadline { usleep(200_000) }
            if Control.lockIsHeld(for: resolvedName) {
                FileHandle.standardError.write(Data(
                    "podium: daemon for '\(resolvedName)' still shutting down after 60s — check `podium stacks`\n".utf8))
                Foundation.exit(1)
            }
        }
        print("down: ok")
        if deleteVolumes {
            if resp.deletedVolumes.isEmpty {
                print("no managed volumes for '\(resolvedName)'")
            } else if host != nil {
                print("volumes deleted: \(resp.deletedVolumes.joined(separator: ", "))")
            } else {
                let volRoot = StackPaths.volumesRoot(for: resolvedName)
                guard !FileManager.default.fileExists(atPath: volRoot) else {
                    FileHandle.standardError.write(Data(
                        "podium: volumes still present at \(volRoot) — check daemon.log\n".utf8))
                    Foundation.exit(1)
                }
                print("volumes deleted: \(volRoot)")
            }
        }
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `reload [--stack <name>] [--host <h>]` — tell the daemon to re-read its stack file and converge.
if command == "reload" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, _) = parseHost(r0)
    let sock = requireSocket(stackName, host: host)
    do {
        let d = try await ControlPlaneClient.reload(
            socketPath: sock, dryRun: false,
            argv: CommandLine.arguments.joined(separator: " "))
        print(CLIRender.reload(d))
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `stacks` — list every stack that has a socket file on disk, with live status.
if command == "stacks" {
    let live = Control.activeStacks()
    if live.isEmpty { print("no running stacks"); Foundation.exit(0) }
    let prune = args.contains("--prune")
    for entry in live {
        if !Control.lockIsHeld(for: entry.name) {
            if prune, let removed = Control.pruneStaleStack(entry.name) {
                print("\(entry.name)  pruned stale \(removed.joined(separator: ", ")); durable data preserved")
            } else {
                print("\(entry.name)  stale socket (run `podium stacks --prune`)")
            }
        } else if let (stack, services) = try? await ControlPlaneClient.listServices(socketPath: entry.socket) {
            let states = services.map { "\($0.id):\($0.state)" }.joined(separator: " ")
            print("\(stack)  \(states)")
        } else {
            print("\(entry.name)  daemon holds lock but is not responding")
        }
    }
    Foundation.exit(0)
}

// `ps [--stack <name>] [--host <h>]` — show service table for one stack.
if command == "ps" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, _) = parseHost(r0)
    let sock = requireSocket(stackName, host: host)
    do {
        let (stack, services) = try await ControlPlaneClient.listServices(socketPath: sock)
        print(CLIRender.ps(stack: stack, services: services))
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock) (is a stack applied?)\n".utf8))
        Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `metrics [--stack <name>] [--host <h>]` — Prometheus text exposition.
if command == "metrics" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, _) = parseHost(r0)
    let sock = requireSocket(stackName, host: host)
    do {
        print(CLIRender.metrics(try await ControlPlaneClient.metrics(socketPath: sock)))
    } catch let error as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(error)\n".utf8))
        Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8))
        Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `top [--stack <name>] [--host <h>] [--once] [--interval <dur>]` — live resource table.
// CPU is a cumulative counter: the live loop diffs client-side over the daemon-supplied
// interval (`sampledAtUsec`), so SSH jitter on --host never enters the denominator.
// `--once` (and non-TTY stdout) prints one frame; the daemon double-samples so CPU% is real.
if command == "top" {
    struct Sample: Decodable {
        let id: String; let state: String
        let cpuUsageUsec: UInt64?; let sampledAtUsec: UInt64
        let memUsageBytes: UInt64?; let memLimitBytes: UInt64?
        let cpus: Int; let cpuPct: Double?
    }
    struct StatsResp: Decodable { let stack: String; let services: [Sample] }

    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    let once = rest.contains("--once") || isatty(STDOUT_FILENO) == 0
    var interval: TimeInterval = 2
    if let i = rest.firstIndex(of: "--interval"), i + 1 < rest.count,
       let d = parseDuration(rest[i + 1]) { interval = d }
    let sock = requireSocket(stackName, host: host)

    func humanBytes(_ n: UInt64) -> String {
        let u = ["B", "KiB", "MiB", "GiB", "TiB"]
        var v = Double(n); var i = 0
        while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i])
    }
    // A cgroup with no limit reports a sentinel near UInt64.max; treat as "no limit".
    func hasLimit(_ n: UInt64?) -> Bool { if let n { return n < (UInt64.max / 2) } else { return false } }

    func render(_ resp: StatsResp, pct: [String: Double?], eol: String = "\n") -> String {
        var lines = ["STACK \(resp.stack)"]
        lines.append("SERVICE".padding(toLength: 22, withPad: " ", startingAt: 0)
            + "CPU%".padding(toLength: 8, withPad: " ", startingAt: 0)
            + "MEM".padding(toLength: 15, withPad: " ", startingAt: 0)
            + "LIMIT".padding(toLength: 11, withPad: " ", startingAt: 0)
            + "STATE")
        for s in resp.services {
            let cpuVal: Double? = pct[s.id] ?? s.cpuPct
            let cpuStr = cpuVal.map { String(format: "%.1f", $0) } ?? "—"
            let memStr = s.memUsageBytes.map(humanBytes) ?? "—"
            let limStr = hasLimit(s.memLimitBytes) ? humanBytes(s.memLimitBytes!) : "—"
            lines.append(s.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                + cpuStr.padding(toLength: 8, withPad: " ", startingAt: 0)
                + memStr.padding(toLength: 15, withPad: " ", startingAt: 0)
                + limStr.padding(toLength: 11, withPad: " ", startingAt: 0)
                + s.state)
        }
        return lines.joined(separator: eol)
    }

    // The daemon pushes frames on its own schedule; transport jitter never
    // enters the CPU calculation.
    func toSample(_ s: Reconciler.StatSample) -> Sample {
        Sample(id: s.id, state: s.state, cpuUsageUsec: s.cpuUsageUsec,
               sampledAtUsec: s.sampledAtUsec, memUsageBytes: s.memUsageBytes,
               memLimitBytes: s.memLimitBytes, cpus: s.cpus, cpuPct: s.cpuPct)
    }
    // CPU% between two sweeps: cumulative usage delta over the daemon-clock
    // delta, so transport jitter never enters the denominator.
    func pctBetween(_ prev: [Sample], _ cur: [Sample]) -> [String: Double?] {
        let prevById = Dictionary(prev.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pct: [String: Double?] = [:]
        for s in cur {
            if let p = prevById[s.id], let a = p.cpuUsageUsec, let b = s.cpuUsageUsec, b >= a {
                let dWall = Double(s.sampledAtUsec &- p.sampledAtUsec)
                pct[s.id] = dWall > 0 ? Double(b - a) / dWall * 100 : nil
            } else { pct[s.id] = nil }
        }
        return pct
    }

    // One-shot: plain frame to stdout, no terminal fiddling. Safe for pipes / `watch`.
    if once {
        // Two frames 200 ms apart provide a real CPU delta.
        var frames: [(stack: String, rows: [Sample])] = []
        do {
            for try await f in ControlPlaneClient.statsStream(socketPath: sock, intervalMs: 200) {
                frames.append((f.stack, f.samples.map(toSample)))
                if frames.count == 2 { break }
            }
        } catch let e as ControlPlaneClientError {
            FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("podium: no daemon at \(sock) (is a stack applied?)\n".utf8))
            Foundation.exit(1)
        }
        guard let last = frames.last else {
            FileHandle.standardError.write(Data("podium: no daemon at \(sock) (is a stack applied?)\n".utf8))
            Foundation.exit(1)
        }
        let pct = frames.count == 2 ? pctBetween(frames[0].rows, last.rows) : [:]
        print(render(StatsResp(stack: last.stack, services: last.rows), pct: pct))
        Foundation.exit(0)
    }

    // Live loop. Raw mode lets us read a single keypress without Enter; the alternate
    // screen + hidden cursor make it a clean full-screen view that restores on exit.
    // We do NOT rely on SIGINT (ContainerizationOS may leave it non-default) — instead
    // a reader thread watches stdin for `q`/`Q`/Ctrl-C(0x03)/Ctrl-D(0x04).
    let outFH = FileHandle.standardOutput
    let terminal = try? Terminal.current
    let raw = { () -> Bool in if let t = terminal, (try? t.setraw()) != nil { return true }; return false }()
    outFH.write(Data("\u{1b}[?1049h\u{1b}[?25l".utf8))   // enter alt screen, hide cursor

    func restore() {
        outFH.write(Data("\u{1b}[?25h\u{1b}[?1049l".utf8))   // show cursor, leave alt screen
        if raw { terminal?.tryReset() }
    }
    func quitNow(_ code: Int32) -> Never { restore(); Foundation.exit(code) }

    // Thread-safe quit flag set by the stdin reader. Only captures the flag (Sendable).
    final class QuitFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }
    let quit = QuitFlag()
    Thread.detachNewThread {
        var b = [UInt8](repeating: 0, count: 1)
        while Darwin.read(STDIN_FILENO, &b, 1) == 1 {
            let c = b[0]
            if c == UInt8(ascii: "q") || c == UInt8(ascii: "Q") || c == 0x03 || c == 0x04 {
                quit.set(); break
            }
        }
    }

    // A detached task drops each pushed frame into a mailbox; this loop's
    // 0.1 s tick exists only for quit-key latency.
    final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: ControlPlaneClient.StatsFrame? = nil
        private var isEnded = false
        func post(_ f: ControlPlaneClient.StatsFrame) { lock.lock(); frame = f; lock.unlock() }
        func end() { lock.lock(); isEnded = true; lock.unlock() }
        func take() -> (ControlPlaneClient.StatsFrame?, Bool) {
            lock.lock(); defer { lock.unlock() }
            let f = frame; frame = nil
            return (f, isEnded)
        }
    }
    let box = Mailbox()
    let intervalMs = UInt32((interval * 1000).rounded())
    let streamTask = Task.detached {
        do {
            for try await f in ControlPlaneClient.statsStream(socketPath: sock, intervalMs: intervalMs) {
                box.post(f)
            }
        } catch {}
        box.end()
    }
    var prevRows: [String: Sample] = [:]
    while !quit.isSet {
        let (f, ended) = box.take()
        if let f {
            let rows = f.samples.map(toSample)
            let pct = pctBetween(Array(prevRows.values), rows)
            for r in rows { prevRows[r.id] = r }
            let frameText = "\u{1b}[H\u{1b}[2J" + render(StatsResp(stack: f.stack, services: rows), pct: pct, eol: "\r\n")
                      + "\r\n\r\n  q or Ctrl-C to quit · refresh \(Int(interval))s"
            outFH.write(Data(frameText.utf8))
        }
        if ended {
            restore()
            FileHandle.standardError.write(Data("podium: lost daemon at \(sock)\n".utf8))
            Foundation.exit(1)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    streamTask.cancel()
    quitNow(0)
}

// Event-driven full-screen service dashboard.
if command == "tui" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    guard rest.isEmpty else { usage() }
    let sock = requireSocket(stackName, host: host)
    Foundation.exit(await runTUI(socketPath: sock))
}

// `stop|start|restart [--stack <name>] [--host <h>] <svc>` — forward to the daemon.
if ["stop", "start", "restart"].contains(command) {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    guard let svcName = rest.first else { usage() }
    let sock = requireSocket(stackName, host: host)
    let action: PbControlRequest.Action =
        command == "stop" ? .stop : command == "start" ? .start : .restart
    do {
        let resp = try await ControlPlaneClient.control(
            socketPath: sock, action: action, id: svcName,
            argv: CommandLine.arguments.joined(separator: " "))
        if resp.ok { print("\(command) \(svcName): ok") }
        else { FileHandle.standardError.write(Data("podium: \(resp.error)\n".utf8)); Foundation.exit(1) }
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `logs [--stack <name>] [--previous] [--tail N] [--since <dur>] <svc> [-f]`
// --previous: read the prior run's log (.log.1); cannot combine with -f.
// --tail N:   print only the last N lines (can combine with -f).
// --since D:  show only lines logged in the last D (e.g. "1h", "30m", "2h15m").
if command == "logs" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    let follow   = rest.contains("-f")
    let previous = rest.contains("--previous")
    if previous && follow {
        FileHandle.standardError.write(Data("podium: --previous reads a static snapshot — drop -f, or omit --previous to follow the live log\n".utf8))
        Foundation.exit(1)
    }
    // Parse --tail N
    var tailN: Int? = nil
    if let tIdx = rest.firstIndex(of: "--tail"), tIdx + 1 < rest.count,
       let n = Int(rest[tIdx + 1]), n > 0 { tailN = n }
    // Parse --since <duration>
    var sinceDur: TimeInterval? = nil
    if let sIdx = rest.firstIndex(of: "--since"), sIdx + 1 < rest.count {
        guard let dur = parseDuration(rest[sIdx + 1]) else {
            FileHandle.standardError.write(Data("podium: invalid --since '\(rest[sIdx + 1])' — use e.g. 1h, 30m, 2h15m\n".utf8))
            Foundation.exit(1)
        }
        sinceDur = dur
    }
    if sinceDur != nil && follow {
        FileHandle.standardError.write(Data("podium: --since reads a static snapshot — drop -f, or omit --since to follow\n".utf8))
        Foundation.exit(1)
    }
    let flags: Set<String> = ["-f", "--previous", "--tail", "--since"]
    let svcName = rest.filter { !flags.contains($0) }.filter { Int($0) == nil }.first ?? ""
    guard !svcName.isEmpty else { usage() }

    // A running daemon serves logs over the control plane. Local file reading
    // below remains useful for a stopped stack; remote reads require a daemon.
    let controlSocket: String? = host != nil
        ? requireSocket(stackName, host: host)
        : Control.resolve(stackName: stackName)
    if let controlSocket {
        let sinceUsec = sinceDur.map {
            Int64(Date().addingTimeInterval(-$0).timeIntervalSince1970 * 1_000_000)
        } ?? 0
        do {
            for try await chunk in ControlPlaneClient.logsStream(
                socketPath: controlSocket, service: svcName,
                tail: Int32(tailN ?? 0), sinceUsec: sinceUsec,
                follow: follow, previous: previous) {
                FileHandle.standardOutput.write(chunk)
            }
            Foundation.exit(0)
        } catch let e as ControlPlaneClientError {
            FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("podium: no daemon at \(controlSocket)\n".utf8)); Foundation.exit(1)
        }
    }

    guard let basePath = Control.resolveLog(stackName: stackName, id: svcName) else {
        FileHandle.standardError.write(Data(
            "podium: no logs for '\(svcName)'\(stackName == nil ? " in any stack" : " in stack '\(stackName!)'")\n".utf8))
        Foundation.exit(1)
    }
    let logPath = previous ? "\(basePath).1" : basePath
    if previous && !FileManager.default.fileExists(atPath: logPath) {
        FileHandle.standardError.write(Data("podium: no previous run for '\(svcName)'\n".utf8))
        Foundation.exit(1)
    }
    guard let h = FileHandle(forReadingAtPath: logPath) else {
        FileHandle.standardError.write(Data("podium: cannot open \(logPath)\n".utf8)); Foundation.exit(1)
    }
    // Timestamp filter for --since; parsing lives in PodiumCore (parseLogTimestamp).
    func passesFilter(_ line: String) -> Bool {
        guard let cutoff = sinceDur.map({ Date().addingTimeInterval(-$0) }) else { return true }
        guard let ts = parseLogTimestamp(line) else { return true }
        return ts >= cutoff
    }
    // --since: read all, filter, print.
    if sinceDur != nil {
        let allData = (try? h.readToEnd()) ?? Data()
        let text = String(decoding: allData, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let out = lines.filter { passesFilter($0) }.joined(separator: "\n")
        if !out.isEmpty { FileHandle.standardOutput.write(Data((out + "\n").utf8)) }
        try? h.close(); Foundation.exit(0)
    }
    if let n = tailN {
        let allData = (try? h.readToEnd()) ?? Data()
        let text = String(decoding: allData, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let tail = Array(lines.suffix(n)).joined(separator: "\n")
        if !tail.isEmpty { FileHandle.standardOutput.write(Data((tail + "\n").utf8)) }
    } else {
        if let d = try? h.readToEnd() { FileHandle.standardOutput.write(d) }
    }
    while follow {
        try await Task.sleep(for: .milliseconds(500))
        if let d = try? h.readToEnd(), !d.isEmpty { FileHandle.standardOutput.write(d) }
    }
    try? h.close()
    Foundation.exit(0)
}

// `exec [--stack <name>] [--host <h>] <svc> <cmd...>` — run a command inside a running container.
if command == "exec" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, r1)      = parseHost(r0)
    guard let invocation = parseExecInvocation(r1) else { usage() }
    let isInteractive = invocation.interactive
    let svc = invocation.service
    let cmd = invocation.argv
    let sock = requireSocket(stackName, host: host)

    // Exec always rides the bidirectional control-plane stream.
    let argvLine = CommandLine.arguments.joined(separator: " ")

    if isInteractive {
            let terminal = try Terminal.current
            let size = try? terminal.size
            let rows = size?.height ?? 24
            let cols = size?.width  ?? 80
            let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
            try terminal.setraw()
            // stdin reader thread → stream; local EOF (Ctrl-D at raw mode
            // still reaches the container as bytes; this covers piped stdin).
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    feed.yield(.stdin(Data(buf[0..<n])))
                }
                feed.yield(.eof)
                feed.finish()
            }
            // SIGWINCH → resize messages.
            // Use ContainerizationOS's retained, mutex-backed async signal
            // stream. A raw DispatchSource closure created in this top-level
            // MainActor context traps under Swift 6 when a global queue invokes
            // it, while a main-queue source can starve during the RPC.
            let winch = AsyncSignalHandler.create(notify: [SIGWINCH])
            let winchTask = Task {
                for await _ in winch.signals {
                    var ws = winsize()
                    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0,
                       ws.ws_row > 0, ws.ws_col > 0 {
                        feed.yield(.resize(rows: ws.ws_row, cols: ws.ws_col))
                    }
                }
            }
            do {
                let code = try await ControlPlaneClient.exec(
                    socketPath: sock, service: svc, argv: cmd,
                    tty: true, rows: rows, cols: cols, clientArgv: argvLine,
                    input: input,
                    onOutput: { out in
                        if case .stdout(let d) = out {
                            d.withUnsafeBytes { raw in
                                guard let base = raw.baseAddress else { return }
                                _ = Darwin.write(STDOUT_FILENO, base, d.count)
                            }
                        }
                    })
                winch.cancel(); winchTask.cancel()
                terminal.tryReset()
                Foundation.exit(code)
            } catch let e as ControlPlaneClientError {
                winch.cancel(); winchTask.cancel()
                terminal.tryReset()
                FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
            } catch {
                winch.cancel(); winchTask.cancel()
                terminal.tryReset()
                FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
            }
    }

        // Non-interactive output streams as it is produced; exit code passes through.
        let (input, feed) = AsyncStream.makeStream(of: ControlPlaneClient.ExecInput.self)
        feed.yield(.eof)   // no stdin plumbing without -t
        feed.finish()
        // Raw write(2), looped for partial writes — NOT FileHandle.write.
        // Darwin's NSFileHandle.writeData is O(n²) across many small chunks
        // (a streaming exec emits thousands), which turned a fast stream into
        // minutes; the -it path already writes raw for the same reason.
        @Sendable func writeAll(_ fd: Int32, _ d: Data) {
            d.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < d.count {
                    let n = Darwin.write(fd, base + off, d.count - off)
                    if n > 0 { off += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    break   // EPIPE/other: best-effort, matches FileHandle giving up
                }
            }
        }
        do {
            let code = try await ControlPlaneClient.exec(
                socketPath: sock, service: svc, argv: cmd,
                tty: false, rows: 0, cols: 0, clientArgv: argvLine,
                input: input,
                onOutput: { out in
                    switch out {
                    case .stdout(let d): writeAll(STDOUT_FILENO, d)
                    case .stderr(let d): writeAll(STDERR_FILENO, d)
                    }
                })
            Foundation.exit(code)
        } catch let e as ControlPlaneClientError {
            FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
}

// `cp [--stack <name>] [--host <h>] <svc>:<path> <local>` (or reverse).
if command == "cp" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    guard rest.count == 2 else { usage() }
    let src = rest[0]; let dst = rest[1]
    let sock = requireSocket(stackName, host: host)

    // Parse <svc>:<path> — returns nil if arg is a plain local path.
    func splitRef(_ s: String) -> (svc: String, path: String)? {
        guard let colonIdx = s.firstIndex(of: ":"), colonIdx != s.startIndex else { return nil }
        let svc = String(s[..<colonIdx]); let path = String(s[s.index(after: colonIdx)...])
        guard !svc.isEmpty, !path.isEmpty else { return nil }
        return (svc, path)
    }

    // Native chunked transfer: no file-size cap, base64, or shell interpolation.
    let argvLine = CommandLine.arguments.joined(separator: " ")
        // Raw write(2), looped — never FileHandle (Darwin's NSFileHandle is
        // O(n²) across many chunks; see the exec non-tty path).
        @Sendable func writeAll(_ fd: Int32, _ d: Data) {
            d.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < d.count {
                    let n = Darwin.write(fd, base + off, d.count - off)
                    if n > 0 { off += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    break
                }
            }
        }
        // Pull-based fd reader for copyIn — one chunk per call, nil at EOF.
        final class FDBox: @unchecked Sendable {
            let fd: Int32
            init(_ fd: Int32) { self.fd = fd }
            func read(_ n: Int) -> Data? {
                var buf = [UInt8](repeating: 0, count: n)
                while true {
                    let r = Darwin.read(fd, &buf, n)
                    if r > 0 { return Data(buf[0..<r]) }
                    if r == 0 { return nil }                 // EOF
                    if errno == EINTR { continue }
                    return nil                                // read error → stop
                }
            }
        }
        do {
            if let (svc, containerPath) = splitRef(src) {
                // container → host (copyOut)
                let outFd: Int32 = dst == "-" ? STDOUT_FILENO : open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if outFd < 0 {
                    FileHandle.standardError.write(Data("podium: cannot write '\(dst)'\n".utf8)); Foundation.exit(1)
                }
                try await ControlPlaneClient.copyOut(
                    socketPath: sock, service: svc, path: containerPath,
                    onChunk: { writeAll(outFd, $0) })
                if dst != "-" {
                    close(outFd)
                    let sz = ((try? FileManager.default.attributesOfItem(atPath: dst))?[.size] as? NSNumber)?.int64Value ?? 0
                    FileHandle.standardError.write(Data("cp: \(src) → \(dst) (\(sz) bytes)\n".utf8))
                }
            } else if let (svc, containerPath) = splitRef(dst) {
                // host → container (copyIn)
                var mode: UInt32 = 0
                if src != "-" {
                    guard FileManager.default.fileExists(atPath: src) else {
                        FileHandle.standardError.write(Data("podium: cannot read '\(src)' — file not found\n".utf8)); Foundation.exit(1)
                    }
                    if let perm = (try? FileManager.default.attributesOfItem(atPath: src))?[.posixPermissions] as? NSNumber {
                        mode = perm.uint32Value
                    }
                }
                let inFd = src == "-" ? STDIN_FILENO : open(src, O_RDONLY)
                if inFd < 0 {
                    FileHandle.standardError.write(Data("podium: cannot read '\(src)'\n".utf8)); Foundation.exit(1)
                }
                // Pull-based: read one chunk each time the transport is ready,
                // so the client never holds more than a chunk in memory.
                let box = FDBox(inFd)
                let written = try await ControlPlaneClient.copyIn(
                    socketPath: sock, service: svc, path: containerPath, mode: mode,
                    clientArgv: argvLine, nextChunk: { box.read(256 * 1024) })
                if src != "-" { close(inFd) }
                FileHandle.standardError.write(Data("cp: \(src) → \(dst) (\(written) bytes)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("podium: one of src or dst must be <svc>:<path>\n".utf8)); Foundation.exit(1)
            }
            Foundation.exit(0)
        } catch let e as ControlPlaneClientError {
            FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("podium: \(error)\n".utf8)); Foundation.exit(1)
    }
}

// `describe [--stack <name>] [--host <h>] <svc>` — full spec + runtime status for one service.
if command == "describe" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    guard let svcName = rest.first else { usage() }
    let sock = requireSocket(stackName, host: host)
    do {
        let result = try await ControlPlaneClient.describe(socketPath: sock, id: svcName)
        print(CLIRender.describe(result))
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `diff [--stack <name>] [--host <h>]` — dry-run reload: show what would change.
if command == "diff" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, _) = parseHost(r0)
    let sock = requireSocket(stackName, host: host)
    do {
        let d = try await ControlPlaneClient.reload(
            socketPath: sock, dryRun: true,
            argv: CommandLine.arguments.joined(separator: " "))
        print(CLIRender.diff(d))
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
    Foundation.exit(0)
}

// `events [--stack <name>] [-f]` — show durable events, optionally following.
if command == "events" {
    let (stackName, r0) = parseStack(Array(args.dropFirst()))
    let (host, rest) = parseHost(r0)
    let follow = rest.contains("-f") || rest.contains("--follow")
    let sock = requireSocket(stackName, host: host)
    do {
        for try await evt in ControlPlaneClient.eventsStream(
            socketPath: sock, after: -1, follow: follow) {
            print(CLIRender.event(evt))
            fflush(stdout)
        }
    } catch let e as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(e)\n".utf8)); Foundation.exit(1)
    } catch {
        FileHandle.standardError.write(Data("podium: no daemon at \(sock)\n".utf8)); Foundation.exit(1)
    }
    Foundation.exit(0)
}

guard ["apply", "up", "selftest"].contains(command) else { usage() }

// `apply` / `up` daemonize by default: re-exec with --foreground, redirect daemon
// stdout+stderr to ~/.podium/<stack>/daemon.log, wait for the control socket to
// appear (confirming start), then return the terminal to the user.
// Pass --foreground to skip re-exec and run the supervisor loop directly (used by
// launchd plists and the re-exec path itself).
if (command == "apply" || command == "up") && !CommandLine.arguments.contains("--foreground") {
    // Determine stack name early so we know the log path before the stack is loaded.
    // We re-parse the raw args here; the full parse happens again inside the child.
    let rawArgs = Array(CommandLine.arguments.dropFirst()) // drop argv[0]
    var stackArgPath = "./stack.json"
    for (i, a) in rawArgs.enumerated() {
        if !a.hasPrefix("-") && i > 0 { stackArgPath = a; break }
    }
    // Load just the name field to build the log path; fall back to basename.
    let stackName: String
    if let data = try? Data(contentsOf: URL(fileURLWithPath: stackArgPath)),
       let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let n    = obj["name"] as? String { stackName = n }
    else if stackArgPath.hasSuffix(".yml") || stackArgPath.hasSuffix(".yaml") {
        // For compose files, use the directory name as a best-effort guess —
        // normalized identically to Stack.loadCompose so parent and child agree.
        stackName = Stack.normalizeName(URL(fileURLWithPath: stackArgPath)
            .deletingLastPathComponent().lastPathComponent)
    }
    else {
        stackName = Stack.normalizeName(
            URL(fileURLWithPath: stackArgPath).deletingLastPathComponent().lastPathComponent)
    }

    let runtimeDir = Control.dir(for: stackName)
    try? FileManager.default.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)
    let daemonLog = StackPaths.daemonLogPath(for: stackName)
    let socketPath = Control.socketPath(for: stackName)

    // Refuse to apply over a live daemon. Without this check, removing the
    // stale socket below would orphan the running daemon and spawn a second one
    // fighting over the same container IDs.
    if Control.lockIsHeld(for: stackName) {
        let pid = Control.lockHolderPid(for: stackName).map { " (pid \($0))" } ?? ""
        FileHandle.standardError.write(Data(
            "podium: stack '\(stackName)' already has a running daemon\(pid) — use `podium reload` to apply changes, or `podium down` first\n".utf8))
        Foundation.exit(1)
    }

    // Remove any stale socket so the poll below reliably detects a fresh start.
    try? FileManager.default.removeItem(atPath: socketPath)

    let binaryPath = CommandLine.arguments[0]
    let child = Process()
    child.executableURL = URL(fileURLWithPath: binaryPath)
    child.arguments = Array(CommandLine.arguments.dropFirst()) + ["--foreground"]
    // Redirect daemon stdout+stderr to the daemon log file.
    FileManager.default.createFile(atPath: daemonLog, contents: nil)
    let logFH = try FileHandle(forWritingTo: URL(fileURLWithPath: daemonLog))
    try logFH.seekToEnd()
    child.standardOutput = logFH
    child.standardError  = logFH
    try child.run()

    // Poll until the control socket appears (daemon ready) or the child dies.
    let deadline = Date().addingTimeInterval(60)
    while !FileManager.default.fileExists(atPath: socketPath) {
        guard child.isRunning, Date() < deadline else {
            FileHandle.standardError.write(Data(
                "podium: daemon failed to start — check \(daemonLog)\n".utf8))
            Foundation.exit(1)
        }
        usleep(100_000) // 0.1s — POSIX C function, safe in async context
    }
    print("[podium] '\(stackName)' started (pid \(child.processIdentifier)) — logs: \(daemonLog)")
    Foundation.exit(0)
}

let stackPath = args.count >= 2 ? args[1] : "./stack.json"

/// Kill-9 recovery phase of selftest. Runs a `<stack>-k9` copy of the stack
/// as a child daemon, SIGKILLs it mid-run, restarts it, and asserts: converged
/// again within 60 s, continuous `starts` counters, and an `adopted-cleanup`
/// event for every service that was running at the kill.
///
/// Call only after the in-process reconciler has shut down: the copy reuses
/// the same service/container IDs.
func runKill9Phase(baseStack: Stack) async -> Bool {
    print("\n== kill-9 recovery ==")
    guard baseStack.services.contains(where: { $0.schedule == nil }) else {
        print("[k9] skipped — stack has no non-cron services")
        return true
    }
    let k9Name = baseStack.name + "-k9"
    let k9Stack = Stack(name: k9Name, services: baseStack.services)
    let tmpPath = NSTemporaryDirectory() + "podium-k9-\(getpid()).json"
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(k9Stack).write(to: URL(fileURLWithPath: tmpPath))
    } catch {
        print("[FAIL] k9: cannot write temp stack file: \(error)")
        return false
    }
    defer { unlink(tmpPath) }

    let sock = Control.socketPath(for: k9Name)
    let k9Dir = Control.dir(for: k9Name)
    try? FileManager.default.createDirectory(atPath: k9Dir, withIntermediateDirectories: true)
    let k9Log = (k9Dir as NSString).appendingPathComponent("daemon.log")

    func spawn() -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["apply", tmpPath, "--foreground"]
        FileManager.default.createFile(atPath: k9Log, contents: nil)
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: k9Log)) {
            p.standardOutput = fh
            p.standardError = fh
        }
        do { try p.run() } catch {
            print("[FAIL] k9: cannot spawn child daemon: \(error)")
            return nil
        }
        return p
    }

    func ps() async -> (stack: String, services: [ServiceStatus])? {
        try? await ControlPlaneClient.listServices(socketPath: sock)
    }
    func converge(within seconds: TimeInterval) async -> (stack: String, services: [ServiceStatus])? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let r = await ps() {
                let regular = r.services.filter { $0.schedule == nil }
                if !regular.isEmpty && regular.allSatisfy({ $0.state == "running" }) { return r }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    guard let child1 = spawn() else { return false }
    guard let before = await converge(within: 60) else {
        print("[FAIL] k9: initial bring-up did not converge in 60s — see \(k9Log)")
        kill(child1.processIdentifier, SIGKILL)
        child1.waitUntilExit()
        return false
    }
    let startsBefore = Dictionary(uniqueKeysWithValues: before.services.map { ($0.id, $0.starts) })
    print("[k9] converged — SIGKILL daemon (pid \(child1.processIdentifier)) mid-run")
    kill(child1.processIdentifier, SIGKILL)
    child1.waitUntilExit()

    guard let child2 = spawn() else { return false }
    let t0 = Date()
    guard let after = await converge(within: 60) else {
        print("[FAIL] k9: did not re-converge within 60s of restart — see \(k9Log)")
        kill(child2.processIdentifier, SIGKILL)
        child2.waitUntilExit()
        return false
    }
    print("[assert] re-converged \(Int(Date().timeIntervalSince(t0)))s after restart ✓")

    var ok = true
    for s in after.services where s.schedule == nil {
        let prior = startsBefore[s.id] ?? 0
        if s.starts <= prior {
            print("[FAIL] k9: \(s.id) starts counter not continuous (\(prior) → \(s.starts))")
            ok = false
        }
    }
    if ok { print("[assert] starts counters continuous across kill-9 ✓") }

    // No-orphan proxy: the restarted daemon must have adopted (torn down by
    // recorded container ID) every service that was running at the kill.
    do {
        var events: [PodiumEvent] = []
        for try await event in ControlPlaneClient.eventsStream(
            socketPath: sock, after: -1, follow: false) {
            events.append(event)
        }
        let adopted = Set(events.filter { $0.type == "adopted-cleanup" }.map { $0.svc })
        let expected = Set(before.services
            .filter { $0.schedule == nil && $0.state == "running" }.map { $0.id })
        if expected.isSubset(of: adopted) {
            print("[assert] adopted-cleanup for every previously-running service ✓ (no orphan VMs)")
        } else {
            print("[FAIL] k9: missing adopted-cleanup for \(expected.subtracting(adopted).sorted())")
            ok = false
        }
    } catch {
        print("[FAIL] k9: could not read events from the recovered daemon")
        ok = false
    }

    _ = try? await ControlPlaneClient.down(
        socketPath: sock, deleteVolumes: false, argv: "podium selftest down")
    child2.waitUntilExit()
    print("[k9] child daemon stopped — runtime dir kept at \(k9Dir)")
    return ok
}

// Kernel resolution: PODIUM_KERNEL env → ~/.podium/vmlinux (installed) → ./vmlinux (dev).
let kernelPath = resolvedKernelPath()

let stack: Stack
do {
    stack = try Stack.load(stackPath)
    try stack.validate()
} catch {
    FileHandle.standardError.write(Data("podium: invalid stack '\(stackPath)': \(error)\n".utf8))
    Foundation.exit(1)
}
// Create runtime dirs before starting any containers (log files need the path to exist).
try Control.makeDirs(for: stack.name)

// The daemon keeps its existing human-oriented call sites, but its durable
// file is bounded JSONL. A direct --foreground terminal still gets raw lines.
var structuredDaemonLogCapture: StructuredDaemonLogCapture?
if (command == "apply" || command == "up"),
   CommandLine.arguments.contains("--foreground") {
    do {
        structuredDaemonLogCapture = try StructuredDaemonLogCapture(stackName: stack.name)
    } catch {
        FileHandle.standardError.write(Data(
            "podium: WARNING: structured daemon logging unavailable: \(error)\n".utf8))
    }
}
print("[podium] stack '\(stack.name)' services=\(stack.services.map { $0.id })")

// Exclusive per-stack lock: exactly one daemon or selftest per stack. The fd
// stays open for the process lifetime; exit releases the lock.
guard let podiumLockFD = Control.acquireLock(for: stack.name) else {
    let pid = Control.lockHolderPid(for: stack.name).map { " (pid \($0))" } ?? ""
    // Selftest SIGKILLs services, so the held lock also protects live stacks from it.
    let hint = command == "selftest"
        ? "refusing to run a destructive selftest against a live stack — bring it down first, or selftest a copy under a different stack name"
        : "`podium reload` applies changes; `podium down` stops it"
    FileHandle.standardError.write(Data(
        "podium: stack '\(stack.name)' is already running\(pid) — \(hint)\n".utf8))
    Foundation.exit(1)
}
_ = podiumLockFD

// Selftest must start from a fresh world: durable state from a previous run
// (a deliberately `failed` crash-loop victim, accumulated crash budgets) would
// poison its assertions. Volumes are never touched. The -k9 state is only
// wiped if no leftover k9 child still holds its lock.
if command == "selftest" {
    let stateDir = URL(fileURLWithPath: StackPaths.stateDir(for: stack.name))
    try? FileManager.default.removeItem(at: stateDir)
    try? FileManager.default.removeItem(at: AppliedSpec.url(stateDirectory: stateDir))
    let k9Name = stack.name + "-k9"
    if !Control.lockIsHeld(for: k9Name) {
        let k9State = URL(fileURLWithPath: StackPaths.stateDir(for: k9Name))
        try? FileManager.default.removeItem(at: k9State)
        try? FileManager.default.removeItem(at: AppliedSpec.url(stateDirectory: k9State))
    }
    print("[selftest] wiped durable state (records/events/applied spec) for a deterministic run")
}

// The store is created inline so it transfers cleanly into the actor.
let r: Reconciler
do {
    r = try Reconciler(stack: stack, stackPath: stackPath,
                   runtime: ContainerizationRuntime(
                       manager: try await makeManager(kernelPath: kernelPath)),
                   store: try StateStore(
                       directory: URL(fileURLWithPath: StackPaths.stateDir(for: stack.name))))
} catch {
    FileHandle.standardError.write(Data(
        "podium: cannot start daemon for '\(stack.name)': \(error)\n".utf8))
    Foundation.exit(1)
}

switch command {
case "apply", "up":
    print("\n== apply (bring-up) ==")
    await r.bootstrap()
    await r.reconcile()

    // Lets a `down` request trigger the shutdown path without a signal.
    let (shutdownStream, shutdownCont) = AsyncStream<Void>.makeStream()

    // Serve the stack-scoped control socket so clients can query/steer this daemon.
    let stackSocketPath = Control.socketPath(for: stack.name)
    await r.startCronScheduler()

    // The Down RPC flags volume deletion for the teardown path below (after
    // containers stop) and triggers the shutdown stream.
    final class DownFlags: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func requestVolumeDeletion() { lock.lock(); v = true; lock.unlock() }
        var deleteVolumes: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }
    let downFlags = DownFlags()
    let stackNameForDown = stack.name
    let controlServer = Task {
        do {
            try await ControlPlaneServer.serve(
                socketPath: stackSocketPath,
                service: PodiumControlService(
                    daemonVersion: podiumDaemonVersion, stackName: stack.name, backend: r,
                    onDown: { deleteVolumes in
                        var scheduled: [String] = []
                        if deleteVolumes {
                            downFlags.requestVolumeDeletion()
                            let volRoot = StackPaths.volumesRoot(for: stackNameForDown)
                            if FileManager.default.fileExists(atPath: volRoot) {
                                scheduled = [volRoot]
                            }
                        }
                        // The yield rides a Task so the ack can flush before
                        // the server winds down.
                        Task { shutdownCont.yield(()); shutdownCont.finish() }
                        return scheduled
                    }),
                onListening: { print("[podium] control socket: \(stackSocketPath)") })
        } catch is CancellationError {
            // normal daemon shutdown
        } catch {
            print("[podium] ERROR: control socket unavailable (\(error))")
            shutdownCont.yield(())
            shutdownCont.finish()
        }
    }
    print("\n[podium] supervising \(stack.services.count) service(s). Ctrl-C / `podium down` to stop.")

    // Wait for SIGINT/SIGTERM/SIGHUP *or* a `podium down` request — whichever comes first.
    // SIGHUP: under the launchd→ssh-localhost model a dropped SSH connection sends SIGHUP.
    let signals = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM, SIGHUP])
    await withTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in signals.signals { break } }
        group.addTask { for await _ in shutdownStream { break } }
        _ = await group.next()
        group.cancelAll()
    }
    print("\n== shutdown ==")
    controlServer.cancel()
    await r.shutdown()
    // Delete volumes only after every container stopped, so nothing holds the
    // mounts. Failure is loud but does not block exit; the CLI reports the
    // surviving path.
    if downFlags.deleteVolumes {
        let volRoot = StackPaths.volumesRoot(for: stack.name)
        if FileManager.default.fileExists(atPath: volRoot) {
            do {
                try FileManager.default.removeItem(atPath: volRoot)
                print("[podium] volumes deleted: \(volRoot)")
            } catch {
                print("[podium] WARN: failed to delete volumes at \(volRoot): \(error)")
            }
        }
    }
    print("[podium] stopped.")

case "selftest":
    var pass = true
    print("\n== apply (initial bring-up) ==")
    await r.bootstrap()
    // Starts counters persist across runs, so assertions use per-run deltas.
    var baseStarts: [String: Int] = [:]
    for s in stack.services { baseStarts[s.id] = await r.startCount(s.id) }
    await r.reconcile()
    // Give an immediately-crashing service's exit time to be recorded, so
    // isRunning() cannot report a container that already exited. Two seconds
    // also covers the first 1 s backoff, so a crash-looper will have starts > 1.
    try await Task.sleep(for: .seconds(2))
    // Cron services are not started by reconcile — skip them in the running check.
    var allUp = true
    for s in stack.services where s.schedule == nil {
        let up = await r.isRunning(s.id)
        let n  = await r.startCount(s.id) - (baseStarts[s.id] ?? 0)
        if !up {
            print("[FAIL] \(s.id) not running after apply"); pass = false; allUp = false
        } else if n > 1 {
            print("[FAIL] \(s.id) crash-looping after apply (restarted \(n - 1) time(s))"); pass = false; allUp = false
        }
    }
    if allUp { print("[assert] all services running ✓") }

    print("\n== idempotency check ==")
    var before: [String: Int] = [:]
    for s in stack.services where s.schedule == nil { before[s.id] = await r.startCount(s.id) }
    await r.reconcile()
    var idempotent = true
    for s in stack.services where s.schedule == nil {
        let now = await r.startCount(s.id)
        if now != before[s.id] { print("[FAIL] \(s.id) restarted on no-op (\(before[s.id]!)→\(now))"); pass = false; idempotent = false }
    }
    print(idempotent ? "[assert] idempotent apply ✓" : "[assert] idempotency FAILED ✗")

    let victim = stack.services[0].id
    let other = stack.services.count > 1 ? stack.services[1].id : victim
    let preKill = await r.startCount(victim)
    let otherStarts = await r.startCount(other)
    print("\n== inject failure on \(victim) ==")
    try await r.injectFailure(victim)
    var healed = false
    for _ in 0..<40 {
        try await Task.sleep(for: .seconds(1))
        let vCount = await r.startCount(victim)
        let vUp = await r.isRunning(victim)
        if vCount > preKill && vUp { healed = true; break }
    }
    if healed {
        let n = await r.startCount(victim)
        print("[assert] \(victim) self-healed ✓ (start #\(n))")
    } else {
        print("[FAIL] \(victim) did not recover"); pass = false
    }
    if other != victim {
        let oc = await r.startCount(other)
        let ou = await r.isRunning(other)
        if oc != otherStarts || !ou { print("[FAIL] \(other) disturbed"); pass = false }
        else { print("[assert] \(other) untouched ✓") }
    }

    // Crash-loop detection: exhaust maxRetries on a service; it must enter `failed`,
    // not restart forever. We drive the loop ourselves — inject a kill, wait for the
    // service to come back up, repeat until the reconciler gives up.
    print("\n== crash-loop detection ==")
    let crashVictim = stack.services.count > 1 ? stack.services[1].id : stack.services[0].id
    // Reset any accumulated fail count so this test is independent of the one above.
    _ = await r.restart(crashVictim)
    for _ in 0..<10 {
        if await r.isRunning(crashVictim) { break }
        try await Task.sleep(for: .seconds(1))
    }
    let maxR = r.tuning.maxRetries
    for attempt in 1...(maxR + 2) {
        // Wait until the service is running (may need to wait through backoff).
        var waited = 0
        while waited < 60 {
            if await r.isRunning(crashVictim) { break }
            if await r.isFailed(crashVictim) { break }
            try await Task.sleep(for: .seconds(1)); waited += 1
        }
        if await r.isFailed(crashVictim) {
            print("[crash-loop] \(crashVictim) reached failed state after \(attempt - 1) inject(s) ✓")
            break
        }
        guard await r.isRunning(crashVictim) else {
            print("[FAIL] crash-loop: \(crashVictim) neither running nor failed after \(waited)s"); pass = false; break
        }
        print("[crash-loop] injecting failure #\(attempt)")
        try? await r.injectFailure(crashVictim)
        try await Task.sleep(for: .milliseconds(200))   // let onExit fire
    }
    let gaveUp = await r.isFailed(crashVictim)
    if gaveUp {
        print("[assert] crash-loop detection ✓ (\(crashVictim) gave up after repeated failures)")
    } else {
        print("[FAIL] crash-loop detection: \(crashVictim) never reached failed state"); pass = false
    }

    // Serve the canonical socket exactly as the daemon does (0600, peer-uid
    // gate) and dial it through the real client path.
    print("\n== control plane handshake ==")
    let controlPath = StackPaths.socketPath(for: stack.name)
    let controlServer = Task {
        try await ControlPlaneServer.serve(
            socketPath: controlPath,
            service: PodiumControlService(
                daemonVersion: podiumDaemonVersion, stackName: stack.name, backend: r))
    }
    var controlInfo: PbInfoResponse? = nil
    for _ in 0..<50 {   // serve() binds asynchronously; retry up to 5 s
        if let info = try? await ControlPlaneClient.getInfo(socketPath: controlPath) {
            controlInfo = info; break
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    if let info = controlInfo,
       info.protocolVersion == PodiumRPCVersion.protocolVersion,
       info.stackName == stack.name,
       info.pid == getpid(),
       info.daemonVersion == podiumDaemonVersion {
        print("[assert] GetInfo handshake over podium.sock ✓ (protocol v\(info.protocolVersion))")
    } else {
        print("[FAIL] GetInfo handshake over podium.sock (got: \(String(describing: controlInfo)))")
        pass = false
    }
    controlServer.cancel()

    print("\n== shutdown ==")
    await r.shutdown()

    // Runs after our own containers are gone: the copy reuses their IDs.
    if await runKill9Phase(baseStack: stack) == false { pass = false }

    print("\n[podium] selftest: \(pass ? "ALL PASS ✓" : "FAILURES ✗")")
    Foundation.exit(pass ? 0 : 1)

default:
    usage()
}
