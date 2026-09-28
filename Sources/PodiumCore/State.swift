// State.swift — the typed per-service state model.
//
// One `ServiceRecord` per service. Two structural rules prevent stale
// asynchronous work from corrupting state:
//
//   1. Generation tokens. Every exit watcher / health poll / liveness probe
//      captures `record.generation` at spawn and is dropped when it no longer
//      matches, closing reload and stale-probe races structurally.
//
//   2. Transitions are total. No code path mutates `phase` except
//      `transition(_:_:now:)`, which validates legality, applies the change,
//      and returns EXACTLY ONE `StateEvent` for the caller to persist and
//      publish. Persistence is the StateStore's job — Core stays
//      I/O-free, so `transition` *returns* the event rather than emitting it.
//      Every failure path carries a `StopReason`; failures are never silent.

import Foundation

// MARK: - Phases and supporting state

public enum ServicePhase: String, Codable, Sendable, Equatable, CaseIterable {
    case pending      // in the spec, not yet started
    case starting     // start in flight (image pull, init containers, boot)
    case running      // container up; readiness tracked separately
    case backingOff   // crashed / failed to start; parked until nextStartAt
    case failed       // gave up (crash loop, init failure); needs user action
    case stopped      // deliberately stopped (user, or removed from spec)
    case exited       // ran to completion; restart policy says stay down
    case scheduled    // cron service parked until the next fire
}

public enum Readiness: Codable, Sendable, Equatable {
    case unknown
    case passing
    case timedOut(after: Date)
}

public struct CronState: Codable, Sendable, Equatable {
    public var lastRun: Date?
    public var lastExit: Int32?

    public init(lastRun: Date? = nil, lastExit: Int32? = nil) {
        self.lastRun = lastRun
        self.lastExit = lastExit
    }
}

/// Why a service is not running — always a *reason*, never silence.
public enum StopReason: Codable, Sendable, Equatable {
    case user                          // explicit `podium stop`
    case spec                          // removed from the spec on reload
    case crashLoop(exit: Int32)        // restart budget exhausted
    case initFailed(step: String)      // init container exited non-zero
    case startFailed(reason: String)   // start error with retries exhausted
}

// MARK: - The record

public struct ServiceRecord: Codable, Sendable, Equatable {
    public let id: String
    /// Incremented on every start — the anti-race token.
    public fileprivate(set) var generation: UInt64
    public fileprivate(set) var phase: ServicePhase
    /// Runtime container identity, kept for adoption/cleanup after a crash.
    public fileprivate(set) var containerID: String?
    public fileprivate(set) var ip: String?
    public fileprivate(set) var starts: Int
    public fileprivate(set) var consecutiveFails: Int
    public fileprivate(set) var lastStartAt: Date?
    public fileprivate(set) var nextStartAt: Date?
    public fileprivate(set) var readiness: Readiness
    public fileprivate(set) var cron: CronState?
    public fileprivate(set) var stopReason: StopReason?

    /// A new service enters the world `.pending`; everything else flows
    /// through `transition`.
    public init(id: String) {
        self.id = id
        self.generation = 0
        self.phase = .pending
        self.containerID = nil
        self.ip = nil
        self.starts = 0
        self.consecutiveFails = 0
        self.lastStartAt = nil
        self.nextStartAt = nil
        self.readiness = .unknown
        self.cron = nil
        self.stopReason = nil
    }

    /// Tests only: place a record in an arbitrary phase without replaying
    /// its history. Internal on purpose — production code cannot reach it.
    internal init(
        id: String, phase: ServicePhase, generation: UInt64 = 0,
        containerID: String? = nil, ip: String? = nil,
        starts: Int = 0, consecutiveFails: Int = 0,
        lastStartAt: Date? = nil, nextStartAt: Date? = nil,
        readiness: Readiness = .unknown, cron: CronState? = nil,
        stopReason: StopReason? = nil
    ) {
        self.id = id
        self.phase = phase
        self.generation = generation
        self.containerID = containerID
        self.ip = ip
        self.starts = starts
        self.consecutiveFails = consecutiveFails
        self.lastStartAt = lastStartAt
        self.nextStartAt = nextStartAt
        self.readiness = readiness
        self.cron = cron
        self.stopReason = stopReason
    }
}

// MARK: - Events

/// Wire-compatible with today's `PodiumEvent.type` strings (Control.swift),
/// plus the new lifecycle kinds this model introduces.
public enum EventKind: String, Codable, Sendable, Equatable {
    case starting
    case started
    case healthy
    case unhealthy
    case unready
    case backoff
    case exited
    case crashed
    case failed
    case stopped
    case scheduled
    case cronFired = "cron-fired"
    case cronDone = "cron-done"
    case adoptedCleanup = "adopted-cleanup"
    case audit
}

/// The single event a successful transition produces. The caller (daemon)
/// persists it and publishes it on the event bus — in that order.
public struct StateEvent: Sendable, Equatable {
    public let kind: EventKind
    public let serviceID: String
    /// Generation AFTER the transition — what any spawned watcher must capture.
    public let generation: UInt64
    public let detail: String?
    public let auditUser: String?
    public let auditArgv: String?

    public init(kind: EventKind, serviceID: String, generation: UInt64, detail: String? = nil,
                auditUser: String? = nil, auditArgv: String? = nil) {
        self.kind = kind
        self.serviceID = serviceID
        self.generation = generation
        self.detail = detail
        self.auditUser = auditUser
        self.auditArgv = auditArgv
    }
}

// MARK: - Triggers

/// What the reconciler decided should happen after a container exit. The
/// *policy* (restart budget, backoff curve, cron vs. plain) lives with the
/// caller; the machine only enforces which phase each disposition may enter.
public enum ExitDisposition: Sendable, Equatable {
    /// → backingOff, retry at `at`. `fresh: true` means the service ran long
    /// enough (caller's `stableSeconds` rule) that this exit starts a NEW
    /// failure streak — `consecutiveFails` becomes 1 instead of incrementing.
    /// The budget reset deliberately lives here, at exit time, not in
    /// `becameReady`: readiness can be instant (no-healthcheck services), so
    /// resetting on ready would let a fast-ready crash-looper evade the
    /// restart budget forever. Uptime is the real stability signal.
    case restart(at: Date, fresh: Bool)
    case giveUp                  // → failed (.crashLoop)
    case complete                // → exited (restart policy: stay down)
    case reschedule(next: Date)  // cron run finished → scheduled
}

public enum TransitionTrigger: Sendable, Equatable {
    /// Begin a start. `user: true` is the explicit `podium start` path —
    /// the only way out of `.failed` besides a daemon restart.
    case startAttempt(user: Bool)
    /// A cron slot fired for a `.scheduled` service.
    case cronFire
    /// The container is up; runtime identity attached.
    case started(containerID: String, ip: String?)
    /// A health-checked replacement is ready. Swap runtime identity in one
    /// persisted running-to-running transition before retargeting host relays.
    case rollingReplaced(containerID: String, ip: String?)
    case becameReady
    case readinessTimedOut
    /// Liveness probe failed; the kill + exit arrive as a separate `.exited`.
    case livenessFailed(detail: String)
    case exited(code: Int32, disposition: ExitDisposition)
    /// The start itself failed (pull error, boot error, init container).
    /// `retryAt` nil means retries are exhausted → `.failed`;
    /// `initStep` non-nil records which init container was at fault.
    case startFailed(reason: String, retryAt: Date?, initStep: String?)
    case userStop
    /// Service no longer present in the spec after a reload.
    case specRemoved
    /// Startup adoption pass: recorded container torn down,
    /// record returns to `.pending` for the normal reconcile. Also resets
    /// `.failed` records so a reboot does not strand a service.
    case adoptionCleanup
    /// Initial parking of a cron service until its first fire.
    case cronScheduled(next: Date)

    /// Short name for error messages and tests.
    public var name: String {
        switch self {
        case .startAttempt(let user): return user ? "startAttempt(user)" : "startAttempt(auto)"
        case .cronFire: return "cronFire"
        case .started: return "started"
        case .rollingReplaced: return "rollingReplaced"
        case .becameReady: return "becameReady"
        case .readinessTimedOut: return "readinessTimedOut"
        case .livenessFailed: return "livenessFailed"
        case .exited: return "exited"
        case .startFailed: return "startFailed"
        case .userStop: return "userStop"
        case .specRemoved: return "specRemoved"
        case .adoptionCleanup: return "adoptionCleanup"
        case .cronScheduled: return "cronScheduled"
        }
    }
}

// MARK: - Errors

public struct TransitionError: Error, Equatable, CustomStringConvertible {
    public let serviceID: String
    public let from: ServicePhase
    public let trigger: String

    public var description: String {
        "illegal transition for '\(serviceID)': \(trigger) while \(from.rawValue)"
    }
}

// MARK: - The total transition function

/// Validates legality, applies the change, and returns the updated record
/// plus EXACTLY ONE event. Illegal (phase, trigger) pairs
/// throw `TransitionError`; nothing else mutates `phase`.
///
/// Total by construction: every trigger switches over every phase with no
/// `default` on the outer trigger switch, so adding a phase or trigger is a
/// compile error until every combination is decided.
public func transition(
    _ record: ServiceRecord,
    _ trigger: TransitionTrigger,
    now: Date = Date()
) throws -> (record: ServiceRecord, event: StateEvent) {
    var r = record

    func illegal() -> TransitionError {
        TransitionError(serviceID: record.id, from: record.phase, trigger: trigger.name)
    }
    func event(_ kind: EventKind, _ detail: String? = nil) -> StateEvent {
        StateEvent(kind: kind, serviceID: r.id, generation: r.generation, detail: detail)
    }
    func clearRuntime() {
        r.containerID = nil
        r.ip = nil
        r.readiness = .unknown
    }

    switch trigger {
    case .startAttempt(let user):
        switch record.phase {
        case .failed:
            guard user else { throw illegal() }
        case .pending, .backingOff, .exited, .stopped:
            break
        case .starting, .running, .scheduled:
            throw illegal()
        }
        r.phase = .starting
        r.generation += 1
        r.starts += 1
        r.lastStartAt = now
        r.nextStartAt = nil
        r.stopReason = nil
        // Explicit user start is a fresh chance: the crash streak resets.
        // Auto restarts keep counting.
        if user { r.consecutiveFails = 0 }
        clearRuntime()
        return (r, event(.starting, user ? "user start" : nil))

    case .cronFire:
        switch record.phase {
        case .scheduled: break
        case .pending, .starting, .running, .backingOff, .failed, .stopped, .exited:
            throw illegal()
        }
        r.phase = .starting
        r.generation += 1
        r.starts += 1
        r.lastStartAt = now
        r.nextStartAt = nil
        r.stopReason = nil
        var cron = r.cron ?? CronState()
        cron.lastRun = now
        r.cron = cron
        clearRuntime()
        return (r, event(.cronFired))

    case .started(let containerID, let ip):
        switch record.phase {
        case .starting: break
        case .pending, .running, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        r.phase = .running
        r.containerID = containerID
        r.ip = ip
        r.readiness = .unknown
        return (r, event(.started))

    case .rollingReplaced(let containerID, let ip):
        switch record.phase {
        case .running: break
        case .pending, .starting, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        r.generation += 1
        r.starts += 1
        r.lastStartAt = now
        r.containerID = containerID
        r.ip = ip
        r.readiness = .passing
        r.nextStartAt = nil
        r.stopReason = nil
        return (r, event(.started, "rolling update"))

    case .becameReady:
        switch record.phase {
        case .running: break
        case .pending, .starting, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        r.readiness = .passing
        // Deliberately does NOT reset consecutiveFails — see ExitDisposition
        // .restart(fresh:) for why the budget reset is exit-time, uptime-based.
        return (r, event(.healthy))

    case .readinessTimedOut:
        switch record.phase {
        case .running: break
        case .pending, .starting, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        r.readiness = .timedOut(after: now)
        return (r, event(.unready))

    case .livenessFailed(let detail):
        switch record.phase {
        case .running: break
        case .pending, .starting, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        // Phase self-loop: the probe's kill lands as a separate `.exited`.
        return (r, event(.unhealthy, detail))

    case .exited(let code, let disposition):
        switch record.phase {
        case .starting, .running: break
        case .pending, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        clearRuntime()
        switch disposition {
        case .restart(let at, let fresh):
            r.phase = .backingOff
            r.consecutiveFails = fresh ? 1 : r.consecutiveFails + 1
            r.nextStartAt = at
            return (r, event(.backoff, "exit \(code)"))
        case .giveUp:
            r.phase = .failed
            r.consecutiveFails += 1
            r.stopReason = .crashLoop(exit: code)
            return (r, event(.failed, "exit \(code); restart budget exhausted"))
        case .complete:
            r.phase = .exited
            if code == 0 { r.consecutiveFails = 0 }
            return (r, event(code == 0 ? .exited : .crashed, "exit \(code)"))
        case .reschedule(let next):
            r.phase = .scheduled
            r.nextStartAt = next
            if code == 0 { r.consecutiveFails = 0 } else { r.consecutiveFails += 1 }
            var cron = r.cron ?? CronState()
            cron.lastExit = code
            r.cron = cron
            return (r, event(.cronDone, "exit \(code)"))
        }

    case .startFailed(let reason, let retryAt, let initStep):
        switch record.phase {
        case .starting: break
        case .pending, .running, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        clearRuntime()
        r.consecutiveFails += 1
        if let retryAt {
            r.phase = .backingOff
            r.nextStartAt = retryAt
            return (r, event(.backoff, reason))
        }
        r.phase = .failed
        if let initStep {
            r.stopReason = .initFailed(step: initStep)
        } else {
            r.stopReason = .startFailed(reason: reason)
        }
        return (r, event(.failed, reason))

    case .userStop:
        switch record.phase {
        case .pending, .starting, .running, .backingOff, .failed, .exited, .scheduled:
            break
        case .stopped:
            throw illegal()  // already stopped — surface it, don't silently no-op
        }
        r.phase = .stopped
        r.stopReason = .user
        r.nextStartAt = nil
        clearRuntime()
        return (r, event(.stopped, "user"))

    case .specRemoved:
        // Legal from every phase: a reload can remove any service at any time.
        switch record.phase {
        case .pending, .starting, .running, .backingOff, .failed, .stopped, .exited, .scheduled:
            break
        }
        r.phase = .stopped
        r.stopReason = .spec
        r.nextStartAt = nil
        clearRuntime()
        return (r, event(.stopped, "removed from spec"))

    case .adoptionCleanup:
        switch record.phase {
        case .starting, .running, .backingOff: break
        case .failed:
            // A daemon restart (usually a host reboot) is a fresh chance:
            // `failed` is often caused by the host itself (e.g. VZ refusing
            // to boot during shutdown). A genuinely broken service fails
            // again through the normal start/backoff path.
            r.consecutiveFails = 0
            r.stopReason = nil
        case .pending, .stopped, .exited, .scheduled:
            throw illegal()
        }
        r.phase = .pending
        r.nextStartAt = nil
        clearRuntime()
        return (r, event(.adoptedCleanup))

    case .cronScheduled(let next):
        switch record.phase {
        case .pending: break
        case .starting, .running, .backingOff, .failed, .stopped, .exited, .scheduled:
            throw illegal()
        }
        r.phase = .scheduled
        r.nextStartAt = next
        return (r, event(.scheduled))
    }
}
