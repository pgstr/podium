# Podium developer guide

## Architecture at a glance

The Swift package is split so the control logic is testable without Apple
virtualization:

| Target | Responsibility |
|---|---|
| `PodiumCore` | stack/Compose parsing, cron, diffing, state model, CLI parsing helpers |
| `PodiumDaemon` | persisted state, reconciler, runtime protocols, diagnostics, rendering |
| `PodiumRPC` | protobuf types, mappings, service implementation, gRPC transport |
| `podium` | macOS executable, Containerization adapter, relay, SSH, process lifecycle |

The real runtime is behind `ContainerRuntime`; daemon tests use a scripted mock.
Generated protobuf Swift is checked in so builds do not need `protoc`.

## Toolchain and setup

Use an Apple-silicon Mac on macOS 26+, Swift 6.2+, and the macOS 26 SDK. The
runtime versions are exact; read [compatibility.md](compatibility.md) before
changing dependencies.

```sh
swift package resolve
make runtime-assets
```

`make runtime-assets` also performs a release build and materializes the
kernel and matching `vminit`. For code-only work where those assets already
exist, use `make build`.

## Required local gates

There is no hosted CI. Run these checks before submitting a change:

```sh
swift test
make build
```

For changes that affect runtime behavior, also run the self-test on real
Apple-silicon hardware with a disposable stack. `make selftest` is destructive
and deliberately refuses a live stack lock:

```sh
make selftest
```

Prefer a focused failing test first, make the minimal implementation change,
then run the full suite. Do not use direct `swift build -c release` as the
release gate: `make build` applies the required virtualization entitlement,
ad-hoc signature, and fresh-inode staging workaround.

## Code generation

Edit `proto/podium.proto`, then regenerate checked-in RPC sources:

```sh
brew install protobuf
make proto
git diff -- proto/podium.proto Sources/PodiumRPC/Generated
```

Update wire mappings, backend/service seams, client calls, and round-trip tests
in the same change. Additive RPCs may retain protocol version 2; incompatible
wire behavior requires an explicit protocol-version decision and migration.

## Load-bearing invariants

1. **One state mutation path.** Every `ServiceRecord` change goes through
   `PodiumCore.transition()` and `Reconciler.apply()`.
2. **Persist before side effects.** Intent/state is durable before starting,
   stopping, or deleting runtime objects.
3. **Generation ownership.** Exit watchers and probes capture a generation and
   become no-ops after replacement. Runtime deletion uses `containerID`, not
   merely the service ID.
4. **Durable data is opt-in destructive.** Normal down/recovery/pruning never
   removes managed volumes or secrets. Only `down --volumes` does so.
5. **One typed control plane.** The canonical private `podium.sock` is gRPC;
   do not add a parallel JSON/socket protocol.
6. **Bounded streaming.** Exec, logs, events, and copy must not buffer an
   unbounded payload. Preserve cancellation and guest-process reaping.
7. **Secret values do not become observability data.** Resolve through a
   `SecretsProvider`, propagate redaction values to log writers, sanitize
   errors before persistence, and test with a canary.
8. **Port exposure is secure by default.** Unqualified host ports bind
   loopback. LAN exposure requires an explicit address or Compose opt-in.
9. **Runtime host/guest versions move together.** The exact Containerization
   pin and `vminit` tag are a compatibility unit.
10. **The stack lock is authoritative.** Never infer liveness only from a
    socket or PID file, and never replace/delete the lock inode while pruning.

## Test map

- `PodiumCoreTests`: parsing, Compose translation, cron/DST, validation, diff,
  state-transition legality and serialization.
- `PodiumDaemonTests`: crash recovery, persist-first behavior, generation
  races, probes, secrets, diagnostics, rotation, metrics, rolling candidates.
- `PodiumRPCTests`: service behavior, version handshake, peer credentials,
  mappings, streaming backpressure/cancellation, copy, audit propagation.
- `selftest`: live VM convergence, idempotency, crash loops, and kill-9
  adoption on an isolated stack.

For concurrency changes, test the stale callback—not just the happy path. For
file formats, include torn-write/corruption recovery. For streaming paths, use
payloads large enough to expose buffering and cancel the client mid-operation.

## Real-Mac acceptance checklist

Use a unique stack name and ports; do not point at a production stack.

```sh
make build
./podium doctor
./podium validate /path/to/acceptance.json
./podium apply /path/to/acceptance.json
./podium ps --stack acceptance
./podium metrics --stack acceptance
./podium events --stack acceptance
./podium down --stack acceptance
```

Add checks specific to the change:

- continuous requests during a published-service reload;
- unhealthy rolling candidate leaves the old response available;
- kill the daemon and verify adoption/counter continuity;
- PTY resize, Ctrl-C, and abrupt client disconnect;
- large exec/copy/log streams with bounded daemon RSS;
- secret canary absent from logs, events, describe, and persisted state;
- network-blocked daemon cold start after `prepare-runtime`;
- stale socket pruning preserves state, logs, secrets, and volumes;
- local and `--host` behavior for every control-plane feature.

Always bring the isolated stack down when complete. Note the platform and tool
versions, commands run, and outcomes in the pull request.

## Reconciler change checklist

Before changing lifecycle behavior:

1. Add the transition trigger and exhaustive legality/event assertions.
2. Add a scripted-runtime test that reproduces the race or failure.
3. Keep state persistence ahead of runtime action.
4. Capture the concrete runtime ID and generation before yielding the actor.
5. Define crash recovery for any new deterministic runtime object ID.
6. Verify late old-generation exits cannot clear new registries or emit events.
7. Run adoption, reconciler, state, and full-suite tests.

Rolling replacement specifically keeps the old container and host listener
live until the candidate is healthy. A failed candidate is deleted without a
state-generation bump; a successful cutover persists the new ID first,
retargets new relay connections, installs new watchers, then stops the old ID.
The listener launches macOS's built-in `/usr/bin/nc` for each accepted upstream
connection because the process owning a Containerization VM cannot open TCP
back into its own interface-scoped vmnet bridge. Existing helpers retain the
old target; listener retargeting affects new connections only. See the recorded
design decision in `ARCHITECTURE.md`.

## Containerization upgrade procedure

1. Change the exact package version in `Package.swift`.
2. Change `containerizationVersion`/`vminitVersion` in the executable in the
   same change.
3. Resolve packages and inspect `Package.resolved` for accidental skew.
4. Rebuild and run the full test suite.
5. Run `make runtime-assets`; verify a version-specific guest path and marker.
6. Cold-start an isolated stack with registry access blocked.
7. Run the real-Mac lifecycle, exec, copy, network, volume, and rolling gates.
8. Update [compatibility.md](compatibility.md) with exact verified platforms.

Do not infer Podium's runtime version from the separately installed Apple
`container` CLI.

## Logging and observability changes

Supervisor output is captured as JSONL by `StructuredDaemonLogCapture` and
written through `RotatingLogSink`. Service output remains timestamp-prefixed
text, redacted before the same bounded sink. Both currently cap each file at
10 MiB and retain three numbered archives.

Metrics names and labels are a public scrape interface. Keep label cardinality
bounded: stack, service, and phase are acceptable; container IDs, errors, and
timestamps are not. Add renderer snapshots and RPC round-trip coverage when a
metric changes.

## Release and distribution

Everyday development is ad-hoc signed. Developer ID release targets and the
direct LaunchAgent template are scaffolded but cannot be accepted until an
Apple Developer subscription and certificate exist. Direct launchd operation,
Keychain-backed secrets, notarization, and packaging remain pending until
their real release gates can run. Follow [releasing.md](releasing.md) once
those credentials are available.

## Documentation discipline

- `README.md` is the short product entry point.
- `docs/operator-guide.md` is the operational source of truth.
- This file is the development source of truth.
- `ARCHITECTURE.md` records durable design decisions.

Keep working plans and acceptance transcripts out of the repository. Git
history and release notes record shipped changes; current behavior belongs in
the documents above. When behavior changes, update the smallest authoritative
document in the same change, and avoid comments or docs that narrate history.
