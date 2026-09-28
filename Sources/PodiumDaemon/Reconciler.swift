// Converges the runtime toward the stack spec. All service state lives in one
// `ServiceRecord` per service, mutated only through `apply` and persisted
// before the runtime acts. Async callbacks capture `record.generation` and are
// dropped once it no longer matches. Runtime handles (containers, relays,
// probe tasks) live in actor-local registries and are never persisted.

import Dispatch
import Foundation
import PodiumCore

struct UnknownServiceError: Error, CustomStringConvertible {
    let id: String
    var description: String { "no state record for service '\(id)'" }
}

struct RollingUpdateError: Error, CustomStringConvertible {
    let id: String
    let reason: String
    var description: String { "rolling update for '\(id)' failed: \(reason); old container kept" }
}

struct StackNameChangeError: Error, CustomStringConvertible {
    let current: String
    let proposed: String
    var description: String {
        "cannot rename running stack '\(current)' to '\(proposed)' during reload; "
            + "bring it down and apply the new stack name"
    }
}

private struct PreparedRuntimeInputs {
    let env: [String]
    let mounts: [RuntimeContainerConfig.Mount]
    let secretValues: [String]
}

public actor Reconciler {
    public struct Tuning: Sendable {
        public var maxRetries = 5
        public var backoffBase = 1.0
        public var backoffCap = 30.0
        public var stableSeconds = 30.0   // ran at least this long → next exit is a fresh failure
        public var livenessInterval: Duration = .seconds(10)
        public var livenessFailThreshold = 3
        public var healthPollInterval: Duration = .seconds(1)
        public init() {}
    }


    public var stack: Stack
    public nonisolated let stackPath: String   // the file this stack was loaded from; used by `reload`
    public nonisolated let tuning: Tuning
    let runtime: any ContainerRuntime
    let store: StateStore
    let secretsProvider: any SecretsProvider

    /// The single source of truth per service. Mutated only via `apply`.
    var records: [String: ServiceRecord] = [:]

    // Runtime handle registries — NOT state.
    var containers: [String: any RuntimeContainer] = [:]
    var portRelays: [String: [any PortRelayHandle]] = [:]
    var liveTasks: [String: Task<Void, Never>] = [:]
    /// Services changed by `reload`; the next pass may start them out of `.stopped`.
    var restartQueue: Set<String> = []
    /// Snapshot records no longer in the spec that still own a container.
    var adoptionLeftovers: [ServiceRecord] = []
    var cronTask: Task<Void, Never>? = nil
    var shuttingDown = false
    var probeSeq = 0
    let daemonStartedAtUsec = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
    var probeLatencySeconds: [String: Double] = [:]
    /// A restarted DNS VM receives a new IP. Existing clients must then be
    /// restarted once so their resolver points at the replacement.
    var dnsClientRestartPending = false

    // Re-entrancy: a health-probe await yields the actor, so a watcher's onExit
    // could re-enter reconcile mid-pass. Serialize passes; coalesce re-triggers.
    var reconciling = false
    var pendingReconcile = false

    /// Throws when the persisted state is unusable (newer schema, corruption).
    public init(stack: Stack, stackPath: String, runtime: any ContainerRuntime,
                store: sending StateStore, tuning: Tuning = Tuning(),
                secretsProvider: (any SecretsProvider)? = nil) throws {
        self.stack = stack
        self.stackPath = stackPath
        self.runtime = runtime
        self.store = store
        self.tuning = tuning
        self.secretsProvider = secretsProvider ?? FileSecretsProvider(stackName: stack.name)
        // Boot from the snapshot so counters survive restarts; records left in
        // a live phase are adopted in `bootstrap()`.
        let snapshot = try store.load()
        for svc in stack.services {
            records[svc.id] = snapshot?.records[svc.id] ?? ServiceRecord(id: svc.id)
        }
        // Removed services may still own containers from before a crash.
        if let snapRecords = snapshot?.records {
            let specIDs = Set(stack.services.map { $0.id })
            adoptionLeftovers = snapRecords.values
                .filter { !specIDs.contains($0.id) && $0.containerID != nil }
        }
    }

    // MARK: bootstrap

    /// Runs once before the first reconcile: commits the spec as applied, tears
    /// down containers recorded by the previous daemon (`ContainerManager` has
    /// no cross-process listing), and returns live and failed records to
    /// `.pending`. Intent phases (.stopped/.exited/.scheduled) are kept.
    public func bootstrap() async {
        // An explicit apply wins over the last applied spec; only warn on drift.
        let specURL = AppliedSpec.url(stateDirectory: store.directory)
        if let applied = AppliedSpec.load(from: specURL) {
            let diff = classifyStackDiff(old: applied, new: stack)
            if applied.name != stack.name || !diff.restarted.isEmpty
                || !diff.started.isEmpty || !diff.stopped.isEmpty {
                print("[recover] WARNING: stack file differs from the last applied spec "
                    + "(changed: \(diff.restarted), added: \(diff.started), removed: \(diff.stopped)) "
                    + "— proceeding with the file")
            }
        }
        do {
            try AppliedSpec.save(stack, to: specURL)
        } catch {
            print("[recover] WARN: could not persist spec.applied.json: \(error)")
        }

        // Orphans of services that left the spec while we were dead.
        for rec in adoptionLeftovers {
            print("[recover] tearing down orphan container '\(rec.containerID ?? rec.id)' "
                + "(service '\(rec.id)' no longer in spec)")
            runtime.delete(rec.containerID ?? rec.id)
        }
        adoptionLeftovers = []

        // Live phases belong to the previous daemon: tear down, then re-converge.
        for svc in stack.services {
            guard let rec = records[svc.id] else { continue }
            switch rec.phase {
            case .starting, .running, .backingOff:
                print("[recover] \(svc.id): recorded as \(rec.phase.rawValue) by the previous "
                    + "daemon — tearing down and re-converging")
                runtime.delete(rec.containerID ?? svc.id)
                // A crash can orphan a rolling candidate before its ID is recorded.
                let candidateID = "\(svc.id)-roll-\(rec.generation + 1)"
                runtime.delete(candidateID)
                // A crash mid-`.starting` can also orphan init containers.
                for i in svc.initContainers.indices {
                    runtime.delete("\(svc.id)-init-\(i)")
                    runtime.delete("\(candidateID)-init-\(i)")
                }
                _ = try? apply(svc.id, .adoptionCleanup)
            case .failed:
                // Often caused by host shutdown; retry after a restart.
                print("[recover] \(svc.id): recorded as failed by the previous daemon — retrying")
                _ = try? apply(svc.id, .adoptionCleanup,
                               detailOverride: "was failed; retrying after daemon restart")
            case .pending, .stopped, .exited, .scheduled:
                break   // no runtime residue, or the phase IS the user's intent
            }
        }
    }

    private func spec(_ id: String) -> ServiceSpec? { stack.services.first { $0.id == id } }

    // MARK: the only mutation path

    /// Validates a transition and persists the snapshot and event before
    /// returning. `detailOverride` replaces the canonical event detail.
    @discardableResult
    func apply(_ id: String, _ trigger: TransitionTrigger,
               detailOverride: String? = nil) throws -> StateEvent {
        guard let rec = records[id] else {
            throw UnknownServiceError(id: id)
        }
        let (newRec, event) = try transition(rec, trigger)
        records[id] = newRec
        let toPersist = StateEvent(kind: event.kind, serviceID: event.serviceID,
                                   generation: event.generation,
                                   detail: detailOverride ?? event.detail)
        do {
            try store.save(StateSnapshot(records: records))
            notifyEventSubscribers(try store.append(toPersist))
        } catch {
            // Persistence failure must not take a workload down.
            print("[state] WARN: persist failed for \(id) (\(trigger.name)): \(error)")
        }
        return event
    }

    /// Persists an informational (non-transition) event.
    private func appendInformational(_ kind: EventKind, svc: String,
                                     generation: UInt64, detail: String?,
                                     auditUser: String? = nil, auditArgv: String? = nil) {
        do {
            notifyEventSubscribers(try store.append(
                StateEvent(kind: kind, serviceID: svc,
                           generation: generation, detail: detail,
                           auditUser: auditUser, auditArgv: auditArgv)))
        } catch {
            print("[state] WARN: could not persist \(kind.rawValue) event for \(svc): \(error)")
        }
    }

    /// Client strings are untrusted even though the peer uid is verified, so
    /// collapse controls and newlines before persisting.
    public func audit(action: AuditAction, serviceID: String?, user: String, argv: String) {
        func oneLine(_ value: String, fallback: String) -> String {
            let clean = value.unicodeScalars.map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
            }
            let text = String(clean).split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return text.isEmpty ? fallback : String(text.prefix(4_096))
        }
        let target = serviceID ?? "@stack"
        appendInformational(
            .audit, svc: target,
            generation: serviceID.flatMap { records[$0]?.generation } ?? 0,
            detail: action.rawValue,
            auditUser: oneLine(user, fallback: "unknown"),
            auditArgv: oneLine(argv, fallback: action.rawValue))
    }

    /// True while `generation` is still the live incarnation of `id`.
    /// Every async callback checks this before touching anything.
    func current(_ id: String, _ generation: UInt64) -> Bool {
        records[id]?.generation == generation
    }

    /// Per-service liveness tuning, falling back to the daemon defaults.
    func effectiveLivenessTuning(for svc: ServiceSpec) -> (interval: Duration, threshold: Int) {
        let interval = svc.livenessIntervalSeconds.map { Duration.seconds($0) }
            ?? tuning.livenessInterval
        let threshold = svc.livenessFailThreshold ?? tuning.livenessFailThreshold
        return (interval, threshold)
    }

    // MARK: reconcile

    /// Converge to desired state. Idempotent; respects stop/fail/backoff gates.
    public func reconcile() async {
        if shuttingDown { return }
        if reconciling { pendingReconcile = true; return }
        reconciling = true
        defer { reconciling = false }

        repeat {
            pendingReconcile = false
            while !shuttingDown {
                // Everything due with ready dependencies starts concurrently;
                // dependents join a later batch.
                let batch = stack.services.filter { svc in
                    if svc.schedule != nil { return false }   // cron-managed
                    guard let rec = records[svc.id] else { return false }
                    let due: Bool
                    switch rec.phase {
                    case .pending:
                        due = true
                    case .backingOff:
                        due = rec.nextStartAt.map { Date() >= $0 } ?? true
                    case .stopped:
                        due = restartQueue.contains(svc.id)   // reload-changed services only
                    default:
                        due = false
                    }
                    guard due else { return false }
                    return svc.dependsOn.allSatisfy { records[$0]?.readiness == .passing }
                }
                guard !batch.isEmpty else { break }
                for svc in batch { restartQueue.remove(svc.id) }
                await withTaskGroup(of: Void.self) { group in
                    for svc in batch {
                        group.addTask { await self.startSequence(svc, trigger: .startAttempt(user: false)) }
                    }
                }
            }
        } while pendingReconcile && !shuttingDown
    }

    // MARK: start sequence

    private var managedDNSEnabled: Bool {
        stack.services.contains { service in
            service.id == ManagedDNS.serviceID
                && service.image == ManagedDNS.image
                && service.volumes.contains {
                    $0.name == ManagedDNS.volumeName && $0.destination == "/config"
                }
        }
    }

    private func runningHostEntries() -> [RuntimeContainerConfig.HostEntry] {
        records.values
            .filter { $0.phase == .running && $0.ip != nil }
            .map { .init(ip: $0.ip!, hostname: $0.id) }
    }

    private func discoveryInputs(for serviceID: String) throws -> ServiceDiscoveryInputs {
        let dnsRecord = records[ManagedDNS.serviceID]
        let dnsIP = dnsRecord?.phase == .running && dnsRecord?.readiness == .passing
            ? dnsRecord?.ip : nil
        return try ServiceDiscovery.inputs(
            serviceID: serviceID,
            managedDNSEnabled: managedDNSEnabled,
            runningEntries: runningHostEntries(),
            dnsIP: dnsIP)
    }

    private func updateManagedDNSHosts() {
        guard managedDNSEnabled else { return }
        let entries = runningHostEntries()
            .filter { $0.hostname != ManagedDNS.serviceID }
        do {
            try DNSHostsStore.update(
                directory: StackPaths.volumeDir(
                    for: stack.name, name: ManagedDNS.volumeName),
                entries: entries)
        } catch {
            print("[dns] WARN: could not refresh managed hosts: \(error)")
        }
    }

    private func markDNSClientsForRestart() {
        guard managedDNSEnabled else { return }
        dnsClientRestartPending = dnsClientRestartPending || records.values.contains {
            $0.id != ManagedDNS.serviceID && $0.phase == .running
        }
    }

    private func restartDNSClientsAfterRecovery() async {
        guard dnsClientRestartPending,
              managedDNSEnabled,
              records[ManagedDNS.serviceID]?.readiness == .passing else { return }
        dnsClientRestartPending = false
        let clients = stack.services
            .map(\.id)
            .filter { $0 != ManagedDNS.serviceID && records[$0]?.phase == .running }
        guard !clients.isEmpty else { return }
        print("[dns] resolver IP changed — restarting clients: \(clients.joined(separator: ", "))")
        for id in clients { _ = await restart(id) }
    }

    private func prepareRuntimeInputs(_ svc: ServiceSpec) throws -> PreparedRuntimeInputs {
        var env = svc.env.map { "\($0.key)=\($0.value)" }
        var secretValues: [String] = []
        if !svc.secrets.isEmpty {
            for (name, key) in svc.secrets {
                let value = try secretsProvider.value(for: key)
                secretValues.append(value)
                env.append("\(name)=\(value)")
            }
            print("[reconcile] \(svc.id): injected \(svc.secrets.count) file secret(s)")
        }

        var mounts: [RuntimeContainerConfig.Mount] = []
        for volume in svc.volumes {
            if let source = volume.source {
                mounts.append(.init(
                    source: source, destination: volume.destination,
                    readOnly: volume.readOnly))
            } else if let name = volume.name {
                let directory = StackPaths.volumeDir(for: stack.name, name: name)
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
                print("[podium] managed volume '\(name)' -> \(directory)")
                print("         (persists across restarts; not removed by `podium down`)")
                mounts.append(.init(
                    source: directory, destination: volume.destination,
                    readOnly: volume.readOnly))
            }
        }
        return PreparedRuntimeInputs(env: env, mounts: mounts, secretValues: secretValues)
    }

    /// Starts one service: persisted `.starting` transition, init containers,
    /// boot, readiness, probes. Errors mark only this record failed.
    private func startSequence(_ svc: ServiceSpec, trigger: TransitionTrigger) async {
        let id = svc.id
        let gen: UInt64
        do {
            gen = try apply(id, trigger).generation
        } catch {
            print("[reconcile] \(id): BUG — illegal start trigger: \(error)")
            return
        }
        print("[reconcile] \(id): not running — starting")
        runtime.delete(id)

        var secretValues: [String] = []
        do {
            let prepared = try prepareRuntimeInputs(svc)
            let envBuf = prepared.env
            let mounts = prepared.mounts
            secretValues = prepared.secretValues
            if id == ManagedDNS.serviceID { updateManagedDNSHosts() }
            let discovery = try discoveryInputs(for: id)

            // Init containers run sequentially to completion before the main
            // container. Non-zero exit → failed immediately (no backoff retry).
            for (i, step) in svc.initContainers.enumerated() {
                print("[init] \(id): step \(i + 1)/\(svc.initContainers.count): "
                    + step.command.joined(separator: " "))
                let initId = "\(id)-init-\(i)"
                runtime.delete(initId)
                let initConfig = RuntimeContainerConfig(
                    id: initId, image: svc.image, cpus: svc.cpus,
                    memoryBytes: svc.memoryMB << 20, rootfsBytes: svc.rootfsGB << 30,
                    command: step.command, env: envBuf, mounts: mounts,
                    hostEntries: discovery.hostEntries, dns: discovery.dns,
                    redactions: secretValues)
                let code = try await runtime.runToCompletion(initConfig)
                runtime.delete(initId)
                guard current(id, gen) else { return }   // superseded while init ran
                guard code == 0 else {
                    print("[init] \(id): step \(i + 1) failed (exit \(code)) — service will not start")
                    _ = try? apply(id, .startFailed(
                        reason: "init step \(i + 1) failed (exit \(code))",
                        retryAt: nil, initStep: "\(i + 1)"))
                    return
                }
                print("[init] \(id): step \(i + 1) ✓")
            }

            // Peer /etc/hosts entries: every service currently running gets an
            // entry. Deps start before dependents, so deps are always visible.
            if !discovery.hostEntries.isEmpty {
                print("[reconcile] \(id): injecting \(discovery.hostEntries.count) peer host(s) into /etc/hosts: "
                    + discovery.hostEntries.map { "\($0.hostname)=\($0.ip)" }.joined(separator: ", "))
            } else if let dns = discovery.dns {
                print("[reconcile] \(id): using managed DNS at \(dns.nameservers.joined(separator: ","))")
            }

            // Rotate the previous run's log so `logs --previous` can read it.
            StackPaths.rotateLog(for: stack.name, id: id)
            let config = RuntimeContainerConfig(
                id: id, image: svc.image, cpus: svc.cpus,
                memoryBytes: svc.memoryMB << 20, rootfsBytes: svc.rootfsGB << 30,
                entrypoint: svc.entrypoint, command: svc.command, args: svc.args,
                workingDirectory: svc.workingDirectory,
                env: envBuf, mounts: mounts,
                hostEntries: discovery.hostEntries, dns: discovery.dns,
                logPath: StackPaths.logPath(for: stack.name, id: id),
                redactions: secretValues)

            let c = try await runtime.createAndStart(config)

            // Superseded while booting (stop/reload during `.starting`)?
            // The new incarnation owns the registries — tear ours down quietly.
            guard current(id, gen), records[id]?.phase == .starting else {
                try? await c.stop()
                runtime.delete(id)
                return
            }
            try apply(id, .started(containerID: id, ip: c.ipAddress))
            containers[id] = c
            updateManagedDNSHosts()
            let rec = records[id]!
            print("[reconcile] \(id): STARTED (start #\(rec.starts))"
                + (rec.ip.map { " ip=\($0)" } ?? ""))

            if let ip = rec.ip, !svc.portForwards.isEmpty {
                let relays = runtime.startPortForwards(svc.portForwards, serviceID: id, ip: ip)
                if !relays.isEmpty { portRelays[id] = relays }
            }

            // Exit watcher, bound to this generation.
            Task { [weak self] in
                let code = await c.wait()
                await self?.onExit(id, generation: gen, exitCode: code)
            }

            if let hc = svc.healthCheck {
                if await waitHealthy(id, generation: gen, command: hc, container: c,
                                     timeoutSeconds: svc.healthTimeoutSeconds) {
                    guard current(id, gen), records[id]?.phase == .running else { return }
                    _ = try? apply(id, .becameReady)
                    print("[reconcile] \(id): HEALTHY ✓")
                    // healthCheck gates startup; livenessCheck (if set) drives the ongoing probe.
                    let (interval, threshold) = effectiveLivenessTuning(for: svc)
                    startLivenessProbe(id: id, generation: gen,
                                       command: svc.livenessCheck ?? hc, container: c,
                                       interval: interval, threshold: threshold)
                    if id == ManagedDNS.serviceID {
                        await restartDNSClientsAfterRecovery()
                    }
                } else {
                    guard current(id, gen), records[id]?.phase == .running else { return }
                    print("[reconcile] \(id): health check did not pass within "
                        + "\(svc.healthTimeoutSeconds)s — dependents will wait")
                    _ = try? apply(id, .readinessTimedOut,
                               detailOverride: "health check not passing after \(svc.healthTimeoutSeconds)s")
                }
            } else {
                // No startup health check: immediately ready.
                if let lc = svc.livenessCheck {
                    let (interval, threshold) = effectiveLivenessTuning(for: svc)
                    startLivenessProbe(id: id, generation: gen, command: lc, container: c,
                                       interval: interval, threshold: threshold)
                }
                _ = try? apply(id, .becameReady)
                if id == ManagedDNS.serviceID {
                    await restartDNSClientsAfterRecovery()
                }
            }
        } catch {
            let safeError = SecretRedactor(values: secretValues)
                .redact(String(describing: error))
            print("[reconcile] \(id): start error — \(safeError)")
            print("            marked failed; fix the cause, then `podium start \(id)`")
            runtime.delete(id)
            guard current(id, gen) else { return }
            _ = try? apply(id, .startFailed(
                reason: "start error: \(safeError)", retryAt: nil, initStep: nil))
        }
    }

    // MARK: exit handling

    /// Stale watchers (superseded generation) are dropped without touching the
    /// registries, which belong to the new incarnation.
    func onExit(_ id: String, generation: UInt64, exitCode: Int32) async {
        guard let rec = records[id], rec.generation == generation else { return }
        let runtimeID = rec.containerID ?? id
        if id == ManagedDNS.serviceID { markDNSClientsForRestart() }
        defer { updateManagedDNSHosts() }

        // Fresh exit: this incarnation owns the registries — clean them up.
        containers[id] = nil
        stopPortRelays(id)
        liveTasks[id]?.cancel(); liveTasks[id] = nil
        runtime.delete(runtimeID)

        if shuttingDown { return }
        // Already left starting/running (user stop, spec removal): this exit is
        // the expected echo, not a crash.
        guard rec.phase == .starting || rec.phase == .running else { return }

        let svc = spec(id)

        // Cron services: record exit code and return to `scheduled` — no restart logic.
        if let expr = svc?.schedule {
            let next = CronSchedule(expr)?.nextDate() ?? Date()
            let msg = exitCode == 0 ? "completed (exit 0)" : "exited with code \(exitCode)"
            print("[cron] \(id): \(msg)")
            _ = try? apply(id, .exited(code: exitCode, disposition: .reschedule(next: next)),
                       detailOverride: "exit \(exitCode)")
            return
        }

        let policy = svc?.restartPolicy ?? .always
        let clean = exitCode == 0
        if policy == .no || (policy == .onFailure && clean) {
            print("[watch] \(id): exited (code \(exitCode)) — restart=\(policy.rawValue), not restarting")
            _ = try? apply(id, .exited(code: exitCode, disposition: .complete))
            return
        }

        // Restart with exponential backoff; give up after maxRetries rapid failures.
        // Uptime ≥ stableSeconds → fresh failure streak (see ExitDisposition.restart).
        let uptime = Date().timeIntervalSince(rec.lastStartAt ?? .distantPast)
        let fresh = uptime >= tuning.stableSeconds
        let n = fresh ? 1 : rec.consecutiveFails + 1
        // Informational raw event; the canonical backoff/failed transition follows.
        appendInformational(clean ? .exited : .crashed, svc: id,
                            generation: rec.generation, detail: "exit \(exitCode)")
        if n > tuning.maxRetries {
            print("[reconcile] \(id): FAILED after \(tuning.maxRetries) attempts — giving up (exit \(exitCode))")
            _ = try? apply(id, .exited(code: exitCode, disposition: .giveUp),
                       detailOverride: "gave up after \(tuning.maxRetries) attempts")
            return
        }
        var backoff = tuning.backoffBase
        for _ in 1..<n { backoff = min(backoff * 2, tuning.backoffCap) }
        print("[watch] \(id): exited (code \(exitCode)) — restart in \(Int(backoff))s (attempt \(n)/\(tuning.maxRetries))")
        _ = try? apply(id, .exited(code: exitCode, disposition: .restart(at: Date().addingTimeInterval(backoff), fresh: fresh)),
                   detailOverride: "\(Int(backoff))s (attempt \(n)/\(tuning.maxRetries))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(backoff))
            await self?.reconcile()
        }
    }

    // MARK: probes

    /// Poll the readiness command until it exits 0 or the timeout elapses.
    /// Aborts (returns false) as soon as the generation is superseded.
    private func waitHealthy(_ id: String, generation: UInt64, command: [String],
                             container c: any RuntimeContainer, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            guard current(id, generation), records[id]?.phase == .running else { return false }
            probeSeq += 1
            if let res = await runTimedProbe(
                serviceID: id, execID: "hc-\(id)-\(probeSeq)",
                command: command, container: c),
               res.exitCode == 0 {
                return true
            }
            // exec can transiently fail just after start; keep polling
            try? await Task.sleep(for: tuning.healthPollInterval)
        }
        return false
    }

    /// Liveness probe bound to one generation; it exits on mismatch, so
    /// cancellation is only an optimization.
    private func startLivenessProbe(id: String, generation: UInt64, command: [String],
                                    container c: any RuntimeContainer,
                                    interval: Duration, threshold: Int) {
        liveTasks[id]?.cancel()
        liveTasks[id] = Task { [weak self] in
            var consecutive = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                guard let self else { break }
                guard await self.current(id, generation) else { break }
                let ok = await self.runProbeOnce(id: id, command: command, container: c)
                if ok {
                    consecutive = 0
                    continue
                }
                consecutive += 1
                print("[liveness] \(id): probe failed (\(consecutive)/\(threshold))")
                if consecutive >= threshold {
                    await self.livenessKill(id: id, generation: generation,
                                            container: c, threshold: threshold)
                    break
                }
            }
        }
    }

    /// The kill decision, serialized on the actor with a final generation
    /// check — a stale probe can never kill (or mis-attribute events to)
    /// a successor container.
    func livenessKill(id: String, generation: UInt64,
                      container c: any RuntimeContainer, threshold: Int) async {
        guard current(id, generation), records[id]?.phase == .running else { return }
        print("[liveness] \(id): unhealthy — killing container")
        _ = try? apply(id, .livenessFailed(
            detail: "liveness probe failed \(threshold) consecutive times"))
        try? await c.kill()
        // The exit arrives via the watcher and takes the normal backoff path.
    }

    private func runProbeOnce(id: String, command: [String], container c: any RuntimeContainer) async -> Bool {
        probeSeq += 1
        return (await runTimedProbe(
            serviceID: id, execID: "lv-\(id)-\(probeSeq)",
            command: command, container: c)?.exitCode ?? 1) == 0
    }

    private func runTimedProbe(
        serviceID: String, execID: String, command: [String],
        container: any RuntimeContainer
    ) async -> RuntimeExecResult? {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try? await container.exec(id: execID, argv: command)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        probeLatencySeconds[serviceID] = Double(elapsed) / 1_000_000_000
        return result
    }

    // MARK: exec

    public struct ExecResult: Sendable {
        public let exitCode: Int32
        public let stdout: Data
        public let stderr: Data
    }

    /// Run a command inside a running container and return buffered stdout/stderr + exit code.
    /// Returns nil if the service is not currently running.
    public func exec(_ id: String, command: [String]) async -> ExecResult? {
        guard let c = containers[id] else { return nil }
        probeSeq += 1
        guard let res = try? await c.exec(id: "ex-\(id)-\(probeSeq)", argv: command) else { return nil }
        return ExecResult(exitCode: res.exitCode, stdout: res.stdout, stderr: res.stderr)
    }

    /// nil = service not running; runtime startup errors are thrown.
    public func execSession(_ id: String, argv: [String], tty: Bool,
                            rows: UInt16, cols: UInt16) async throws -> (any ExecSession)? {
        guard let c = containers[id] else { return nil }
        probeSeq += 1
        return try await c.startExecSession(id: "ex-\(id)-\(probeSeq)", argv: argv,
                                            tty: tty, rows: rows, cols: cols)
    }

    public func importFile(_ id: String, hostPath: String, containerPath: String, mode: UInt32) async -> CopyOutcome {
        guard let c = containers[id] else { return .notRunning }
        do {
            try await c.importFile(hostPath: hostPath, containerPath: containerPath, mode: mode)
            return .ok
        } catch { return .failed("\(error)") }
    }

    public func exportFile(_ id: String, containerPath: String, hostPath: String) async -> CopyOutcome {
        guard let c = containers[id] else { return .notRunning }
        do {
            try await c.exportFile(containerPath: containerPath, hostPath: hostPath)
            return .ok
        } catch { return .failed("\(error)") }
    }

    // MARK: control plane (podium stop/start/restart)

    public func stop(_ id: String) async -> Bool {
        guard spec(id) != nil else { return false }
        let runtimeID = records[id]?.containerID ?? id
        if id == ManagedDNS.serviceID { markDNSClientsForRestart() }
        liveTasks[id]?.cancel(); liveTasks[id] = nil
        restartQueue.remove(id)
        // Transition FIRST (persisted stop intent), THEN stop the container:
        // the watcher's exit finds phase != running and is dropped — the stop
        // is never misread as a crash.
        if records[id]?.phase != .stopped {
            _ = try? apply(id, .userStop)
        }
        updateManagedDNSHosts()
        if let c = containers[id] {
            print("[control] stopping \(id)")
            try? await c.stop()
            containers[id] = nil
            stopPortRelays(id)
            runtime.delete(runtimeID)
        }
        return true
    }

    public func start(_ id: String) async -> Bool {
        guard let svc = spec(id) else { return false }
        print("[control] starting \(id)")
        if svc.schedule != nil {
            // Cron service: fire immediately; bypass the schedule gate for this one run.
            guard containers[id] == nil else { return true }
            if records[id]?.phase == .pending {
                let next = svc.schedule.flatMap { CronSchedule($0)?.nextDate() } ?? Date()
                _ = try? apply(id, .cronScheduled(next: next))
            }
            if records[id]?.phase == .scheduled {
                await startSequence(svc, trigger: .cronFire)
            } else {
                await startSequence(svc, trigger: .startAttempt(user: true))
            }
            return true
        }
        switch records[id]?.phase {
        case .stopped, .failed, .exited, .backingOff, .pending:
            // An explicit start bypasses the dependency gate, like `docker start`.
            await startSequence(svc, trigger: .startAttempt(user: true))
        default:
            break   // already starting/running
        }
        return true
    }

    public func restart(_ id: String) async -> Bool {
        guard await stop(id) else { return false }
        return await start(id)
    }

    /// Test hook: hard-kill a service to exercise self-heal.
    public func injectFailure(_ id: String) async throws {
        guard let c = containers[id] else { return }
        print("[test] injecting failure: SIGKILL -> \(id)")
        try await c.kill()
    }

    public func isRunning(_ id: String) -> Bool { records[id]?.phase == .running }
    public func isReady(_ id: String) -> Bool { records[id]?.readiness == .passing }
    public func isFailed(_ id: String) -> Bool { records[id]?.phase == .failed }
    public func startCount(_ id: String) -> Int { records[id]?.starts ?? 0 }

    // MARK: snapshot (podium ps)

    /// Point-in-time status of every declared service.
    public func snapshot() -> [ServiceStatus] {
        stack.services.map { s in
            let rec = records[s.id] ?? ServiceRecord(id: s.id)
            let depsReady = s.dependsOn.allSatisfy { records[$0]?.readiness == .passing }
            let state: String
            if s.schedule != nil {
                // Cron: running (mid-fire) | failed | scheduled (idle).
                switch rec.phase {
                case .running: state = "running"
                case .failed: state = "failed"
                default: state = "scheduled"
                }
            } else {
                switch rec.phase {
                case .running: state = "running"
                case .failed: state = "failed"
                case .stopped: state = "stopped"
                case .exited: state = "exited"
                case .backingOff: state = depsReady ? "backoff" : "waiting"
                case .pending, .starting: state = depsReady ? "pending" : "waiting"
                case .scheduled: state = "scheduled"   // unreachable for non-cron
                }
            }
            let nextFire: Date? = (s.schedule != nil && rec.phase != .running)
                ? s.schedule.flatMap { CronSchedule($0)?.nextDate() } : nil
            return ServiceStatus(id: s.id, state: state,
                                 ready: rec.readiness == .passing,
                                 starts: rec.starts,
                                 startedAt: rec.phase == .running ? rec.lastStartAt : nil,
                                 ip: rec.ip, portForwards: s.portForwards,
                                 schedule: s.schedule, lastRun: rec.cron?.lastRun,
                                 lastExit: rec.cron?.lastExit, nextRun: nextFire)
        }
    }

    // MARK: stats (podium top)

    /// One row of resource stats for a service. CPU is the raw cumulative counter;
    /// the client computes %. `cpuPct` is pre-filled only by the `--once` double-sample.
    public struct StatSample: Encodable, Sendable {
        public let id: String
        public let state: String           // mirrors ServiceStatus.state
        public let cpuUsageUsec: UInt64?   // cumulative CPU time; nil if not running / read failed
        public let sampledAtUsec: UInt64   // daemon monotonic clock at sample time
        public let memUsageBytes: UInt64?
        public let memLimitBytes: UInt64?
        public let cpus: Int               // configured vCPUs, for optional normalisation
        public let cpuPct: Double?         // only set by statsOnce()

        public init(id: String, state: String, cpuUsageUsec: UInt64?, sampledAtUsec: UInt64,
                    memUsageBytes: UInt64?, memLimitBytes: UInt64?, cpus: Int, cpuPct: Double?) {
            self.id = id; self.state = state
            self.cpuUsageUsec = cpuUsageUsec; self.sampledAtUsec = sampledAtUsec
            self.memUsageBytes = memUsageBytes; self.memLimitBytes = memLimitBytes
            self.cpus = cpus; self.cpuPct = cpuPct
        }
    }

    /// Monotonic microseconds from the daemon's clock. The client divides cumulative
    /// usage deltas by the delta of this, so network/SSH jitter never enters the interval.
    private func nowUsec() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
    }

    /// One stats sweep. Preserves `snapshot()` ordering so the table is stable
    /// frame-to-frame. Per-container read failures degrade to blank cells, not a dead frame.
    public func stats() async -> [StatSample] {
        var out: [StatSample] = []
        for s in snapshot() {
            let t = nowUsec()
            guard let c = containers[s.id] else {
                out.append(StatSample(id: s.id, state: s.state, cpuUsageUsec: nil,
                                      sampledAtUsec: t, memUsageBytes: nil, memLimitBytes: nil,
                                      cpus: spec(s.id)?.cpus ?? 1, cpuPct: nil))
                continue
            }
            let st = try? await c.statistics()
            out.append(StatSample(id: s.id, state: s.state,
                                  cpuUsageUsec: st?.cpuUsageUsec, sampledAtUsec: t,
                                  memUsageBytes: st?.memUsageBytes,
                                  memLimitBytes: st?.memLimitBytes,
                                  cpus: spec(s.id)?.cpus ?? 1, cpuPct: nil))
        }
        return out
    }

    /// Low-cardinality scrape snapshot. Starts are durable because they come
    /// from persisted state.
    public func metrics() async -> PodiumMetrics {
        let uptime = Double(nowUsec() &- daemonStartedAtUsec) / 1_000_000
        let rows = snapshot().map { status -> PodiumMetrics.Service in
            let starts = UInt64(max(0, status.starts))
            let relayCount = portRelays[status.id, default: []]
                .reduce(UInt64(0)) { $0 &+ $1.connectionCount }
            return PodiumMetrics.Service(
                id: status.id, phase: status.state,
                starts: starts, restarts: starts > 0 ? starts - 1 : 0,
                probeLatencySeconds: probeLatencySeconds[status.id],
                relayConnections: relayCount)
        }
        return PodiumMetrics(stack: stack.name, daemonUptimeSeconds: uptime, services: rows)
    }

    /// Self-contained snapshot for `--once`: two reads ~`gapMs` apart so each row
    /// carries a real `cpuPct` without the client holding sample history.
    public func statsOnce(gapMs: UInt64 = 200) async -> [StatSample] {
        let first = await stats()
        try? await Task.sleep(nanoseconds: gapMs * 1_000_000)
        let second = await stats()
        let prev = Dictionary(first.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return second.map { s in
            guard let p = prev[s.id], let a = p.cpuUsageUsec, let b = s.cpuUsageUsec,
                  b >= a else { return s }                       // counter reset / no prior → leave nil
            let dWall = Double(s.sampledAtUsec &- p.sampledAtUsec)
            let pct = dWall > 0 ? Double(b - a) / dWall * 100 : nil
            return StatSample(id: s.id, state: s.state, cpuUsageUsec: s.cpuUsageUsec,
                              sampledAtUsec: s.sampledAtUsec, memUsageBytes: s.memUsageBytes,
                              memLimitBytes: s.memLimitBytes, cpus: s.cpus, cpuPct: pct)
        }
    }

    // MARK: describe

    public struct DescribeResult: Encodable, Sendable {
        public let id: String
        public let stack: String
        public let state: String
        public let ready: Bool
        public let starts: Int
        public let startedAt: Date?
        public let ip: String?                  // vmnet IPv4 while running
        public let portForwards: [PortForward]  // host↔container port mappings
        public let image: String
        public let cpus: Int
        public let memoryMB: UInt64
        public let rootfsGB: UInt64
        public let entrypoint: [String]?
        public let command: [String]?
        public let args: [String]?
        public let volumes: [VolumeMount]
        public let env: [String: String]
        public let healthCheck: [String]?
        public let livenessCheck: [String]?
        public let restartPolicy: String
        public let logPath: String
        // Cron fields (nil for regular services).
        public let schedule: String?
        public let lastRun: Date?
        public let lastExit: Int32?
        public let nextRun: Date?
        /// Why the service is in `failed` state, if it is.
        public let failReason: String?

        public init(id: String, stack: String, state: String, ready: Bool, starts: Int,
                    startedAt: Date?, ip: String?, portForwards: [PortForward],
                    image: String, cpus: Int, memoryMB: UInt64, rootfsGB: UInt64,
                    command: [String]?, entrypoint: [String]? = nil, args: [String]? = nil,
                    volumes: [VolumeMount], env: [String: String],
                    healthCheck: [String]?, livenessCheck: [String]?,
                    restartPolicy: String, logPath: String,
                    schedule: String?, lastRun: Date?, lastExit: Int32?, nextRun: Date?,
                    failReason: String?) {
            self.id = id; self.stack = stack; self.state = state; self.ready = ready
            self.starts = starts; self.startedAt = startedAt
            self.ip = ip; self.portForwards = portForwards
            self.image = image; self.cpus = cpus; self.memoryMB = memoryMB; self.rootfsGB = rootfsGB
            self.entrypoint = entrypoint; self.command = command; self.args = args
            self.volumes = volumes; self.env = env
            self.healthCheck = healthCheck; self.livenessCheck = livenessCheck
            self.restartPolicy = restartPolicy; self.logPath = logPath
            self.schedule = schedule; self.lastRun = lastRun; self.lastExit = lastExit
            self.nextRun = nextRun; self.failReason = failReason
        }
    }

    public func describe(_ id: String) -> DescribeResult? {
        guard let svc = spec(id) else { return nil }
        let st = snapshot().first { $0.id == id }!
        let rec = records[id]
        return DescribeResult(
            id: id, stack: stack.name,
            state: st.state, ready: st.ready, starts: st.starts, startedAt: st.startedAt,
            ip: rec?.ip, portForwards: svc.portForwards,
            image: svc.image, cpus: svc.cpus, memoryMB: svc.memoryMB, rootfsGB: svc.rootfsGB,
            command: svc.command, entrypoint: svc.entrypoint, args: svc.args,
            volumes: svc.volumes, env: svc.env,
            healthCheck: svc.healthCheck, livenessCheck: svc.livenessCheck,
            restartPolicy: svc.restartPolicy.rawValue,
            logPath: StackPaths.logPath(for: stack.name, id: id),
            schedule: svc.schedule, lastRun: rec?.cron?.lastRun, lastExit: rec?.cron?.lastExit,
            nextRun: st.nextRun,
            failReason: rec?.phase == .failed ? rec?.stopReason.map(failReasonText) : nil
        )
    }

    /// Human-readable failure reason shown by `describe`.
    private func failReasonText(_ reason: StopReason) -> String {
        switch reason {
        case .user: return "stopped by user"
        case .spec: return "removed from spec"
        case .crashLoop(let exit):
            return "crash loop: gave up after \(tuning.maxRetries) attempts (last exit \(exit))"
        case .initFailed(let step): return "init step \(step) failed"
        case .startFailed(let reason): return reason
        }
    }

    // MARK: events

    /// Events with seq > `after` (-1 for everything retained). Sequence numbers
    /// are continuous across daemon restarts, so `-f` resumes without gaps or
    /// duplicates.
    public func getEvents(after seq: Int) -> [PodiumEvent] {
        let persisted: [PersistedEvent]
        do {
            persisted = try store.loadEvents()
        } catch {
            print("[state] WARN: could not read events.jsonl: \(error)")
            return []
        }
        return persisted
            .filter { Int($0.seq) > seq }
            .map(asPodiumEvent)
    }

    private func asPodiumEvent(_ p: PersistedEvent) -> PodiumEvent {
        PodiumEvent(seq: Int(p.seq), timestamp: p.timestamp,
                    stack: stack.name, svc: p.serviceID,
                    type: p.kind.rawValue, detail: p.detail,
                    generation: p.generation,
                    auditUser: p.auditUser, auditArgv: p.auditArgv)
    }

    // MARK: event push

    private var eventSubscribers: [UUID: AsyncStream<PodiumEvent>.Continuation] = [:]

    /// Backlog (seq > `after`) followed by live events as they are appended.
    /// The stream stays open until the consumer cancels. No gap and no
    /// duplicate is possible between backlog and live: both happen in one
    /// synchronous actor turn, and appends only occur on this actor.
    public func eventStream(after seq: Int) -> AsyncStream<PodiumEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PodiumEvent.self, bufferingPolicy: .unbounded)
        for e in getEvents(after: seq) { continuation.yield(e) }
        let id = UUID()
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropEventSubscriber(id) }
        }
        return stream
    }

    private func dropEventSubscriber(_ id: UUID) {
        eventSubscribers[id] = nil
    }

    /// Pushes a just-persisted event to every live `events -f` stream.
    private func notifyEventSubscribers(_ p: PersistedEvent) {
        guard !eventSubscribers.isEmpty else { return }
        let e = asPodiumEvent(p)
        for c in eventSubscribers.values { c.yield(e) }
    }

    // MARK: cron scheduler

    /// Starts the cron loop if any service has a schedule. The next wake time
    /// is recomputed from the wall clock each iteration, so drift cannot
    /// accumulate and no minute is checked twice or skipped.
    public func startCronScheduler() {
        guard stack.services.contains(where: { $0.schedule != nil }) else { return }
        // Park every cron service in `.scheduled` so fires are legal transitions.
        for svc in stack.services {
            guard let expr = svc.schedule, records[svc.id]?.phase == .pending else { continue }
            let next = CronSchedule(expr)?.nextDate() ?? Date()
            _ = try? apply(svc.id, .cronScheduled(next: next))
        }
        cronTask = Task { [weak self] in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            while !Task.isCancelled {
                guard let next = cal.nextDate(after: Date(),
                                              matching: DateComponents(second: 1),
                                              matchingPolicy: .nextTime) else { break }
                let gap = next.timeIntervalSinceNow
                if gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
                if Task.isCancelled { break }
                await self?.checkCronJobs()
            }
        }
    }

    private func checkCronJobs() async {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        for svc in stack.services {
            guard let expr = svc.schedule, let cron = CronSchedule(expr) else { continue }
            guard cron.matches(now) else { continue }
            guard let rec = records[svc.id], rec.phase == .scheduled else {
                if records[svc.id]?.phase == .starting || records[svc.id]?.phase == .running {
                    print("[cron] \(svc.id): skipping fire — already running")
                }
                continue
            }
            // At most one fire per matching minute.
            if let lr = rec.cron?.lastRun, cal.isDate(lr, equalTo: now, toGranularity: .minute) {
                continue
            }
            print("[cron] \(svc.id): schedule '\(expr)' matched — firing")
            await startSequence(svc, trigger: .cronFire)
        }
    }

    // MARK: rolling replacement

    private func waitRollingHealthy(
        _ serviceID: String, candidateID: String, command: [String],
        container: any RuntimeContainer, timeoutSeconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            probeSeq += 1
            if let result = await runTimedProbe(
                serviceID: serviceID,
                execID: "hc-\(candidateID)-\(probeSeq)",
                command: command, container: container),
               result.exitCode == 0 {
                return true
            }
            try? await Task.sleep(for: tuning.healthPollInterval)
        }
        return false
    }

    /// Start and health-check a candidate while the old container and its host
    /// listeners remain live. Once ready, persist the new identity, atomically
    /// retarget listeners for new connections, then drain/stop the old VM.
    private func rollingReplace(_ svc: ServiceSpec) async throws {
        let id = svc.id
        guard let oldRecord = records[id], oldRecord.phase == .running,
              oldRecord.readiness == .passing,
              let oldContainer = containers[id] else {
            throw RollingUpdateError(id: id, reason: "service is not running and ready")
        }
        let relays = portRelays[id] ?? []
        guard !svc.portForwards.isEmpty,
              relays.count == svc.portForwards.count,
              relays.allSatisfy(\.canRetarget) else {
            throw RollingUpdateError(id: id, reason: "host relays cannot be retargeted")
        }

        let candidateID = "\(id)-roll-\(oldRecord.generation + 1)"
        runtime.delete(candidateID)
        let prepared: PreparedRuntimeInputs
        let discovery: ServiceDiscoveryInputs
        do {
            prepared = try prepareRuntimeInputs(svc)
            discovery = try discoveryInputs(for: id)
        } catch {
            throw RollingUpdateError(id: id, reason: String(describing: error))
        }

        for (index, step) in svc.initContainers.enumerated() {
            let initID = "\(candidateID)-init-\(index)"
            runtime.delete(initID)
            let config = RuntimeContainerConfig(
                id: initID, image: svc.image, cpus: svc.cpus,
                memoryBytes: svc.memoryMB << 20, rootfsBytes: svc.rootfsGB << 30,
                command: step.command, env: prepared.env, mounts: prepared.mounts,
                hostEntries: discovery.hostEntries, dns: discovery.dns,
                redactions: prepared.secretValues)
            let code: Int32
            do {
                code = try await runtime.runToCompletion(config)
            } catch {
                runtime.delete(initID)
                throw RollingUpdateError(id: id, reason: "init step \(index + 1): \(error)")
            }
            runtime.delete(initID)
            guard code == 0 else {
                throw RollingUpdateError(id: id, reason: "init step \(index + 1) exited \(code)")
            }
        }

        let config = RuntimeContainerConfig(
            id: candidateID, image: svc.image, cpus: svc.cpus,
            memoryBytes: svc.memoryMB << 20, rootfsBytes: svc.rootfsGB << 30,
            entrypoint: svc.entrypoint, command: svc.command, args: svc.args,
            workingDirectory: svc.workingDirectory,
            env: prepared.env, mounts: prepared.mounts,
            hostEntries: discovery.hostEntries, dns: discovery.dns,
            // Both generations briefly append to one bounded log. Rotation is
            // deferred until a later cold restart so neither writer is orphaned.
            logPath: StackPaths.logPath(for: stack.name, id: id),
            redactions: prepared.secretValues)

        let candidate: any RuntimeContainer
        do {
            candidate = try await runtime.createAndStart(config)
        } catch {
            runtime.delete(candidateID)
            throw RollingUpdateError(id: id, reason: String(describing: error))
        }

        let ready: Bool
        if let check = svc.healthCheck {
            ready = await waitRollingHealthy(
                id, candidateID: candidateID, command: check,
                container: candidate, timeoutSeconds: svc.healthTimeoutSeconds)
        } else {
            ready = true
        }
        guard ready, let newIP = candidate.ipAddress else {
            try? await candidate.stop()
            runtime.delete(candidateID)
            throw RollingUpdateError(
                id: id, reason: ready ? "candidate has no IP address" : "candidate did not become healthy")
        }

        let transitionEvent: StateEvent
        do {
            transitionEvent = try apply(
                id, .rollingReplaced(containerID: candidateID, ip: newIP))
        } catch {
            try? await candidate.stop()
            runtime.delete(candidateID)
            throw RollingUpdateError(id: id, reason: String(describing: error))
        }

        liveTasks[id]?.cancel()
        liveTasks[id] = nil
        containers[id] = candidate
        updateManagedDNSHosts()
        for relay in relays {
            guard relay.retarget(ip: newIP) else {
                // canRetarget is a preflight contract; this is an adapter bug.
                print("[reload] ERROR: relay for \(id) refused a promised retarget")
                continue
            }
        }

        let generation = transitionEvent.generation
        Task { [weak self] in
            let code = await candidate.wait()
            await self?.onExit(id, generation: generation, exitCode: code)
        }
        if let check = svc.healthCheck {
            let effective = effectiveLivenessTuning(for: svc)
            startLivenessProbe(
                id: id, generation: generation,
                command: svc.livenessCheck ?? check, container: candidate,
                interval: effective.interval, threshold: effective.threshold)
        } else if let check = svc.livenessCheck {
            let effective = effectiveLivenessTuning(for: svc)
            startLivenessProbe(
                id: id, generation: generation, command: check,
                container: candidate, interval: effective.interval,
                threshold: effective.threshold)
        }

        let oldContainerID = oldRecord.containerID ?? id
        try? await oldContainer.stop()
        runtime.delete(oldContainerID)
        print("[reload] \(id): rolling update complete; relay -> \(newIP)")
    }

    // MARK: reload

    /// Pure diff of `newStack` against the running stack.
    public func classify(_ newStack: Stack) -> StackDiff {
        classifyStackDiff(old: stack, new: newStack)
    }

    /// Converges to `newStack`: removed services stop, eligible published
    /// services roll behind their listeners, other changed services restart,
    /// and new services start. Each affected record is transitioned before its
    /// container stops, so the old container's late exit is dropped rather
    /// than counted as a crash.
    public func reload(newStack: Stack) async throws -> StackDiff {
        let oldStack = stack
        guard newStack.name == oldStack.name else {
            throw StackNameChangeError(current: oldStack.name, proposed: newStack.name)
        }
        let oldIds = oldStack.services.map { $0.id }
        let newIdSet = Set(newStack.services.map { $0.id })
        let oldIdSet = Set(oldIds)

        var stopped: [String] = []
        let changed = newStack.services.filter { newSvc in
            guard let oldSvc = oldStack.services.first(where: { $0.id == newSvc.id }) else {
                return false
            }
            return newSvc != oldSvc
        }
        let restarted = changed.map(\.id)

        // 1. Stop services that no longer exist in the new spec.
        for id in oldIds where !newIdSet.contains(id) {
            stopped.append(id)
            let runtimeID = records[id]?.containerID ?? id
            liveTasks[id]?.cancel(); liveTasks[id] = nil
            if records[id]?.phase != .stopped {
                _ = try? apply(id, .specRemoved)
            }
            if let c = containers[id] {
                print("[reload] removing \(id)")
                try? await c.stop()
                containers[id] = nil
                stopPortRelays(id)
                runtime.delete(runtimeID)
            }
            records[id] = nil
        }

        if !stopped.isEmpty {
            // Save again so removed records disappear even without a later transition.
            try store.save(StateSnapshot(records: records))
            updateManagedDNSHosts()
        }

        // Make removals durable before a later candidate can fail. Successful
        // rolling replacements are committed one by one for the same reason.
        if !stopped.isEmpty {
            stack = Stack(name: oldStack.name,
                          services: oldStack.services.filter { newIdSet.contains($0.id) })
            do {
                try AppliedSpec.save(stack, to: AppliedSpec.url(stateDirectory: store.directory))
            } catch {
                print("[reload] WARN: could not persist spec.applied.json: \(error)")
            }
        }

        // 2. Roll eligible services behind their existing host listeners.
        // Changed ports or dependencies fall back to a conventional restart.
        var rolled = Set<String>()
        for newSvc in changed {
            guard let oldSvc = oldStack.services.first(where: { $0.id == newSvc.id }) else {
                continue
            }
            let relays = portRelays[newSvc.id] ?? []
            let eligible = !newSvc.portForwards.isEmpty
                && newSvc.portForwards == oldSvc.portForwards
                && newSvc.dependsOn == oldSvc.dependsOn
                && newSvc.schedule == nil && oldSvc.schedule == nil
                && records[newSvc.id]?.phase == .running
                && records[newSvc.id]?.readiness == .passing
                && containers[newSvc.id] != nil
                && relays.count == newSvc.portForwards.count
                && relays.allSatisfy(\.canRetarget)
            guard eligible else { continue }

            print("[reload] rolling changed \(newSvc.id)")
            try await rollingReplace(newSvc)
            rolled.insert(newSvc.id)

            var services = stack.services
            if let index = services.firstIndex(where: { $0.id == newSvc.id }) {
                services[index] = newSvc
            }
            stack = Stack(name: stack.name, services: services)
            do {
                try AppliedSpec.save(stack, to: AppliedSpec.url(stateDirectory: store.directory))
            } catch {
                print("[reload] WARN: could not persist spec.applied.json: \(error)")
            }
        }

        // 3. Stop changed services that cannot be rolled, then queue them for restart.
        for newSvc in changed where !rolled.contains(newSvc.id) {
            let runtimeID = records[newSvc.id]?.containerID ?? newSvc.id
            liveTasks[newSvc.id]?.cancel(); liveTasks[newSvc.id] = nil
            if records[newSvc.id]?.phase != .stopped {
                _ = try? apply(newSvc.id, .userStop, detailOverride: "reload: spec changed")
            }
            if let c = containers[newSvc.id] {
                print("[reload] restarting changed \(newSvc.id)")
                try? await c.stop()
                containers[newSvc.id] = nil
                stopPortRelays(newSvc.id)
                runtime.delete(runtimeID)
            }
            restartQueue.insert(newSvc.id)
        }
        updateManagedDNSHosts()

        let started = newStack.services.map { $0.id }.filter { !oldIdSet.contains($0) }
        let unchanged = newStack.services.map { $0.id }
            .filter { !restarted.contains($0) && !started.contains($0) }

        // 4. Commit new spec (memory + spec.applied.json), create records for
        // new services, reconcile.
        stack = newStack
        if !managedDNSEnabled { dnsClientRestartPending = false }
        do {
            try AppliedSpec.save(stack, to: AppliedSpec.url(stateDirectory: store.directory))
        } catch {
            print("[reload] WARN: could not persist spec.applied.json: \(error)")
        }
        for svc in newStack.services where records[svc.id] == nil {
            records[svc.id] = ServiceRecord(id: svc.id)
        }
        await reconcile()

        print("[reload] done — started:\(started) stopped:\(stopped) restarted:\(restarted) unchanged:\(unchanged)")
        return StackDiff(started: started, stopped: stopped, restarted: restarted, unchanged: unchanged)
    }

    // MARK: shutdown

    private func stopPortRelays(_ id: String) {
        portRelays[id]?.forEach { $0.stop() }
        portRelays[id] = nil
    }

    /// Topological order of all services (dependencies before dependents).
    /// Reversed, this gives the safe shutdown order (dependents before dependencies).
    private func topologicalOrder() -> [String] {
        var result: [String] = []
        var visited = Set<String>()
        func visit(_ id: String) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            for dep in (spec(id)?.dependsOn ?? []) { visit(dep) }
            result.append(id)
        }
        for svc in stack.services { visit(svc.id) }
        return result
    }

    /// Stops running services dependents-first without recording transitions,
    /// so the next startup's adoption pass sees the last live phase.
    public func shutdown() async {
        shuttingDown = true
        cronTask?.cancel(); cronTask = nil
        for t in liveTasks.values { t.cancel() }
        liveTasks.removeAll()
        for id in topologicalOrder().reversed() {
            guard let c = containers[id] else { continue }
            let runtimeID = records[id]?.containerID ?? id
            print("[shutdown] stopping \(id)")
            try? await c.stop()
            runtime.delete(runtimeID)
            containers[id] = nil
            stopPortRelays(id)
        }
        containers.removeAll()
    }
}
