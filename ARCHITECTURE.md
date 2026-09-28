# Podium architecture

This document describes Podium's **state model**, **control plane**, and the
module boundaries that make both testable, plus the design decisions behind
them.

Fixed constraints: a single macOS host, Apple silicon, the
`apple/containerization` runtime, and one daemon process per stack.

---

## 1. Module layout

Four targets in one Swift package:

```
Sources/
  PodiumCore/       # pure logic, no I/O, no Containerization import
    Spec.swift        (stack schema, validation incl. service-ID rules)
    Compose.swift     (Compose translation, ${VAR} interpolation)
    Cron.swift
    State.swift       (state machine types, transitions, generation logic)
    Parsing.swift     (durations, ports, memory strings, log timestamps)
  PodiumDaemon/     # reconciler, state store, runtime seam, domain wire models
  PodiumRPC/        # generated proto, mappings, typed gRPC service/transport
  podium/           # macOS CLI/bootstrap, Containerization adapter, port relay
Tests/
  PodiumCoreTests/
  PodiumDaemonTests/
  PodiumRPCTests/
```

`PodiumCore` never imports `Containerization` or touches the filesystem. Logic
that needs either lives in `PodiumDaemon` and delegates its decisions to pure
`PodiumCore` functions.

`PodiumDaemon` does not import `Containerization` either: the reconciler drives
a `ContainerRuntime` protocol, and the Containerization adapter lives in the
`podium` executable. Lifecycle races are therefore covered by unit tests
against a scripted mock runtime.

---

## 2. State model

### 2.1 Principles

Persist-first: every state transition is durable **before** it is acted on.
Each service has a single typed record owned by a `StateStore`; the reconciler
consumes state rather than owning it.

### 2.2 On-disk layout

```
~/.podium/<stack>/
  lock                 # flock'd for the daemon lifetime — single-instance guarantee
  daemon.pid
  podium.sock          # gRPC control socket (0600)
  state/
    manifest.json      # schema version + pointer to current snapshot
    state.json         # atomic snapshot (write tmp → fsync → rename)
    events.jsonl       # append-only event log, size-rotated
  spec.applied.json    # the resolved spec actually running (post-Compose, post-defaults)
  logs/  volumes/  secrets.env
```

JSON snapshot plus JSONL journal rather than SQLite: state is tiny (KBs),
transitions are infrequent, atomic rename is crash-safe on APFS, and the files
are debuggable with `cat`. The `StateStore` protocol leaves room for SQLite if
event queries ever outgrow JSONL.

### 2.3 The service record

```swift
struct ServiceRecord: Codable {
  let id: String
  var generation: UInt64        // incremented on every start; the anti-race token
  var phase: ServicePhase
  var containerID: String?      // runtime container identity, for adoption/cleanup
  var ip: String?
  var starts: Int
  var consecutiveFails: Int
  var lastStartAt, nextStartAt: Date?
  var readiness: Readiness      // .unknown | .passing | .timedOut(after: Date)
  var cron: CronState?          // lastRun, lastExit
  var stopReason: StopReason?   // .user | .spec | .crashLoop(exit) | .initFailed(step) | .startFailed(reason)
}

enum ServicePhase: String, Codable {
  case pending, starting, running, backingOff, failed, stopped, exited, scheduled
}
```

Two rules keep asynchronous work from corrupting state:

1. **Generation tokens.** Exit watchers, health polls, and liveness probes
   capture the generation they were started for. Every callback checks
   `record.generation == myGeneration` before acting, so stale callbacks are
   dropped. This closes reload and stale-probe races structurally rather than
   through careful flag ordering.
2. **Transitions are total.** `transition(_:_:)` in `PodiumCore` validates
   legality (for example, `failed → running` only via an explicit user `start`
   or the startup adoption pass) and returns exactly one event. The reconciler
   persists the record and event before acting. No code path mutates a phase
   any other way, so every failure has a persisted reason.

### 2.4 Crash recovery and adoption

Daemon startup:

1. Acquire `flock` on `lock`, failing loudly if it is already held.
2. Load `state.json`. A newer schema version is refused; an older one is
   migrated through versioned migration functions.
3. **Adoption pass:** for every record with a `containerID`, tear the container
   down through the runtime (`ContainerManager` has no cross-process listing,
   so recorded IDs are the only handle on orphans) and emit `adopted-cleanup`.
   Those records return to `pending` so the normal reconcile pass brings them
   back. `failed` records also return to `pending` with a fresh restart budget,
   because a failure is often caused by the host itself (for example, VZ
   refusing to boot during shutdown). Only `stopped` (operator intent),
   `exited`, and `scheduled` survive a restart untouched.
4. Reconcile.

`podium selftest` verifies this end to end: it `kill -9`s a daemon mid-run,
restarts it, and asserts that the stack converges within 60 s with no orphaned
VMs and continuous `starts` counters.

### 2.5 Reconciler behavior

A start error marks only that record `failed(reason:)`; the pass continues.
Readiness timeout is a visible state with an event, not a silent wait.
Services whose dependencies are ready start concurrently in batches. Probe
timing is configurable per service, and Compose health-check timing maps onto
those fields.

---

## 3. Control plane

### 3.1 gRPC over a Unix domain socket

`grpc-swift-2`, SwiftNIO, and swift-protobuf are already in the dependency
graph through `containerization`, so gRPC adds no new top-level dependencies.
It provides streaming (logs, exec, cp, events), typed errors with status
codes, proto-based schema evolution, and generated clients.

The socket is `~/.podium/<stack>/podium.sock`, mode 0600 inside a 0700
directory. The server also verifies each peer's UID via `LOCAL_PEERCRED` and
rejects non-matching callers, which still holds if the socket permissions are
ever loosened by hand.

### 3.2 Service definition

See [`proto/podium.proto`](proto/podium.proto). In outline:

```proto
service PodiumControl {
  rpc GetInfo(InfoRequest) returns (InfoResponse);          // version handshake — first call
  rpc ListServices(Empty) returns (PsResponse);             // ps
  rpc Describe(ServiceRef) returns (DescribeResponse);
  rpc Stats(StatsRequest) returns (stream StatsSample);     // top: server pushes frames
  rpc Metrics(Empty) returns (MetricsResponse);            // Prometheus snapshot
  rpc Control(ControlRequest) returns (ControlResponse);    // stop/start/restart
  rpc Reload(ReloadRequest) returns (ReloadResponse);       // also serves `diff` with dry_run=true
  rpc Down(DownRequest) returns (DownResponse);             // incl. daemon-side volume deletion
  rpc Logs(LogsRequest) returns (stream LogChunk);          // tail/since/follow server-side
  rpc Events(EventsRequest) returns (stream Event);         // resume via sequence number
  rpc Exec(stream ExecInput) returns (stream ExecOutput);   // bidi: stdin/resize up, output/exit down
  rpc CopyIn(stream FileChunk) returns (CopyResponse);
  rpc CopyOut(CopyRequest) returns (stream FileChunk);
}
```

`GetInfo` returns `{daemonVersion, protocolVersion, stackName, pid}`, and
clients refuse to proceed on a protocol-major mismatch. `Exec` is a
bidirectional stream: interactive mode is `tty=true` plus resize messages, and
output is chunked and back-pressured, so a large `exec cat` never buffers in
daemon memory. `CopyIn`/`CopyOut` use the runtime's native file transfer
rather than a shell, so paths are never interpolated.

Every mutating RPC carries client metadata (user, command line), which the
daemon writes to the event log as the audit trail.

### 3.3 Server concurrency

Each connection runs in its own structured-concurrency task, and long-running
streams (`logs -f`, `events -f`, stats) are independent of unary calls, so a
hung client cannot wedge the control plane.

### 3.4 Remote access

`--host` tunnels the gRPC socket over SSH, reusing a `ControlMaster`
connection and caching the remote home directory so repeated commands are
cheap. Because logs, exec, and copy all flow through the daemon, they behave
identically locally and remotely. The proto layer is transport-agnostic, so a
TCP listener with mTLS could be added later without changing the service.

---

## 4. Cross-cutting decisions

**State schema versioning.** `manifest.json` and `state.json` carry a schema
version; the store refuses newer schemas and has a tested migration hook.
`stack.json`/`spec.applied.json` are currently versionless. Before any
breaking stack-schema change, add an explicit stack schema version and
fixtures rather than silently reinterpreting old files.

**Name validation.** Service IDs and stack names must match
`^[a-z0-9]([a-z0-9_-]{0,30}[a-z0-9])?$`, enforced in `Stack.validate()`. IDs
feed container IDs, filenames, and hostnames.

**Logging.** Daemon output is captured as JSONL with levels and ISO
timestamps. Daemon and redacted service logs have a 10 MiB cap per file plus
three numbered archives; `--tail`/`--since` read bounded windows from the end
of the file.

**Secrets.** Secrets live in `~/.podium/<stack>/secrets.env`. The provider
refuses symlinks, non-regular files, any mode other than 0600, and the wrong
owner. `SecretsProvider` keeps a future Keychain backend swappable.

**Port forwards.** `PortForward.bindAddress` defaults to `127.0.0.1`. Compose
`127.0.0.1:8080:80` maps to it, and a bare `8080:80` binds loopback unless the
service sets `x-podium: { publish: true }`.

**Managed service DNS.** Top-level `"dns": true` adds a pinned CoreDNS service
with an atomically refreshed hosts file. DNS-enabled clients get the sidecar's
IP, the `podium.local` search domain, and no static peer hosts. When the DNS VM
is replaced, running clients restart once after it is ready, so their resolver
address cannot go stale. Stacks without `"dns": true` use static `/etc/hosts`
discovery.

**Process model.** One daemon per stack: isolation matches vmnet separation
and keeps the blast radius small.

---

## 5. Design decisions

**Readiness does not reset the fail budget.** If `becameReady` reset
`consecutiveFails`, a service that becomes ready instantly (no health check)
and then crashes would evade the restart budget forever. The budget resets at
exit time instead, when the service ran for at least the stable-uptime window
(`ExitDisposition.restart(at:fresh:)`), or on an explicit user `start`.

**An explicit apply wins over `spec.applied.json`.** `podium apply <file>`
expresses user intent, so the daemon proceeds with the file and re-commits it
as the applied spec, only warning about drift. Crash recovery is unaffected:
launchd re-runs `apply` with the same path, and adoption plus the persisted
records recover runtime state regardless of file drift.

**Upstream TCP for port relays runs in `/usr/bin/nc`.** On macOS 26, the
process that owns a Containerization VM receives `EHOSTUNREACH` when opening
TCP back into its own interface-scoped vmnet bridge, although ordinary host
processes can reach the same guest IP. Podium therefore owns the loopback/LAN
listener, counters, and retarget state, but launches the built-in macOS `nc`
for each accepted connection, with the client socket as stdin/stdout. During a
rolling update, existing connections stay on the old target and new
connections use the retargeted IP. This needs no extra package.

**Rolling replacement.** For a ready service with published ports, `reload`
starts a candidate container while the old one and its host listener stay
live. If the candidate becomes healthy, Podium persists its identity, retargets
the listeners, and then stops the old VM. A failed candidate is deleted and
the old generation keeps serving.
