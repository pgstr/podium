# Podium operator guide

This guide takes a new operator from an empty supported Mac to a supervised
stack, then covers routine operation, recovery, backup, and upgrades.

## 1. Prepare the Mac

Podium supports Apple-silicon Macs on macOS 26 or newer, with Swift 6.2+ and
the macOS 26 SDK. Install and initialize Apple's
[`container`](https://github.com/apple/container) tooling once, following its
upstream host setup, so a compatible Linux kernel is available. Podium itself
pins both the host Containerization library and guest `vminit` to 0.46.0; see
[compatibility.md](compatibility.md).

From the Podium checkout:

```sh
make runtime-assets
./podium doctor
```

`runtime-assets` builds and ad-hoc signs Podium, installs the newest available
kernel at `~/.podium/vmlinux`, and pre-caches matching `vminit`. `doctor` should
show PASS for the kernel, vminit, stack locks/sockets, signing, and disk-usage
checks. The `container tool` check may be WARN after the kernel is installed;
Podium does not invoke that CLI during normal service operation.

To install the command in `/usr/local/bin`:

```sh
make install-cli
podium doctor
```

The installation step uses `sudo` only when copying the executable. Stack
state and VMs run as the logged-in user.

## 2. Define and start a stack

Only `name`, service `id`, and `image` are required. A small published service
looks like this:

```json
{
  "name": "demo",
  "services": [
    {
      "id": "web",
      "image": "docker.io/library/busybox:1.37",
      "command": ["/bin/sh", "-c", "mkdir -p /www; echo hello >/www/index.html; exec busybox httpd -f -p 8080 -h /www"],
      "cpus": 1,
      "memoryMB": 512,
      "rootfsGB": 1,
      "healthCheck": ["wget", "-q", "-O-", "http://127.0.0.1:8080"],
      "livenessCheck": ["wget", "-q", "-O-", "http://127.0.0.1:8080"],
      "ports": [{"hostPort": 8080, "containerPort": 8080}]
    }
  ]
}
```

Host ports bind `127.0.0.1` by default. Set `bindAddress` to `0.0.0.0` only
when the service must be reachable from the LAN.

Validate, cache the service image if desired, and apply:

```sh
podium validate demo.json
podium pull docker.io/library/alpine:3.21
podium apply demo.json
podium ps --stack demo
curl http://127.0.0.1:8080
```

`apply` daemonizes and returns when the control socket is ready. Use
`podium apply demo.json --foreground` to keep supervisor output in the current
terminal. Applying the same running stack again is refused; edit the original
file and use `podium diff` and `podium reload`.

## 3. Files and durability

Each stack owns a private `~/.podium/<stack>/` directory:

| Path | Purpose | Durable? |
|---|---|---|
| `podium.sock`, `daemon.pid`, `lock` | local control and ownership | runtime metadata |
| `state/` and `spec.applied.json` | records, counters, events, applied spec | yes |
| `daemon.log[.1-.3]` | structured JSONL supervisor log | bounded history |
| `logs/<service>.log[.1-.3]` | timestamped service stdout/stderr | bounded history |
| `volumes/<name>/` | managed volume contents | yes |
| `secrets.env` | strict per-stack file secrets | yes, private |

A normal `podium down` stops VMs but preserves state, logs, volumes, and
secrets. `podium down --volumes` additionally deletes all managed volumes and
is intentionally destructive.

## 4. Stack schema essentials

A service may set:

- `entrypoint`, `command`, `args`, `workingDirectory`, `env`, `cpus`,
  `memoryMB`, and `rootfsGB`;
- `dependsOn` for health-gated startup ordering;
- `healthCheck`, `healthTimeoutSeconds`, `livenessCheck`,
  `livenessIntervalSeconds`, and `livenessFailThreshold`;
- `restartPolicy`: `always`, `on-failure`, or `no`;
- `ports`: integers or `{hostPort, containerPort, bindAddress}` objects;
- `volumes`: host binds (`source`) or managed volumes (`name`), each with a
  guest `destination` and optional `readOnly`;
- `secrets`: environment variable name to key in the stack secret file;
- `init`: ordered one-shot commands; and
- `schedule`: a five-field cron expression for one-shot scheduled services.

A native service with only `command` treats that array as the complete argv.
Adding `entrypoint` or
`args` activates the split model: `entrypoint` overrides the image ENTRYPOINT
(`[]` clears it), `command` overrides the image CMD, and `args` appends extra
arguments. For example:

```json
"entrypoint": ["/init", "/opt/app/wrapper.sh"],
"command": ["gateway"],
"args": ["run"]
```

Podium applies the same split when translating Compose, so Compose `command`
keeps the image ENTRYPOINT and Compose `entrypoint` overrides it.
See `examples/process-split.json` and `examples/compose-entrypoint.yml`.

`dependsOn` gates startup on readiness. By default, service-name resolution
uses `/etc/hosts` written at container start, so restart an already-running
dependent after its backend receives a new VM address. For dynamic discovery,
enable the stack-local resolver at the top level:

```json
"dns": true
```

Podium then generates and supervises `podium-dns`, makes ordinary services
wait for it, and configures them to resolve both `app` and
`app.podium.local`. Records refresh automatically when services start, stop,
or receive new addresses. If the DNS VM itself gets a new address, Podium
restarts running clients once after the replacement is healthy so their
resolver configuration is rebound. See `examples/dns-discovery.json`.

### Managed ingress

A top-level `ingress` block generates and supervises a Caddy service. The
listener is loopback-only by default, and each route maps one hostname to a
declared backend service and container port:

```json
"ingress": {
  "hostPort": 18082,
  "routes": [
    {"host": "app.home.local", "service": "app", "port": 8080}
  ]
}
```

Podium validates the hostnames and targets, adds a `podium-ingress` service,
waits for every routed backend, writes the Caddy configuration, and publishes
Caddy's port 80 at `127.0.0.1:<hostPort>`. Set `bindAddress` to `0.0.0.0` only
for intentional LAN exposure. Configure local or homelab DNS to resolve each
hostname to the Podium host; for a one-off check without DNS:

```sh
curl --resolve app.home.local:18082:127.0.0.1 http://app.home.local:18082/
```

See `examples/managed-ingress.json` for a minimal stack. Add `"dns": true`, as
shown in `examples/dns-discovery.json`, when ingress should follow backend IP
changes without restarting Caddy.

## 5. Compose input

Any command that accepts a stack file also accepts `.yml` or `.yaml`. Podium
translates the file in memory:

```sh
podium validate docker-compose.yml
podium migrate docker-compose.yml > translated-stack.json
podium apply docker-compose.yml
```

Supported mappings include images, entrypoints, commands, working directories,
environment/`env_file`, bind and named volumes, `depends_on`, health checks,
restart policy, CPU/memory limits, and published ports. Compose ports become
real host relays and bind loopback unless an explicit host IP or
`x-podium: {publish: true}` opts into wider exposure.

Podium prints warnings for unsupported fields such as `build`, `networks`, and
`profiles`, and for unsupported per-probe timeout details. Read every warning;
use `migrate` to inspect the exact native result before first apply.

## 6. Secrets

Create the stack directory and install an owner-only regular file:

```sh
mkdir -p ~/.podium/demo
install -m 600 /path/to/demo-secrets.env ~/.podium/demo/secrets.env
```

For a file containing `WEB_TOKEN=secret-value`, a service maps it without
putting the value in the stack:

```json
"secrets": {"API_TOKEN": "WEB_TOKEN"}
```

Podium rejects symlinks, non-regular files, the wrong owner, and any mode other
than `0600`. Secret values are redacted from captured service output and from
supervisor errors, events, and descriptions. Never place the secret file in
the repository.

## 7. Routine operation

```sh
podium stacks
podium ps --stack demo
podium describe --stack demo web
podium logs --stack demo --tail 100 web
podium logs --stack demo --since 1h web
podium logs --stack demo web -f
podium events --stack demo -f
podium top --stack demo
podium tui --stack demo
podium metrics --stack demo
podium exec --stack demo -it web /bin/sh
podium cp --stack demo web:/tmp/result.txt ./result.txt
podium stop --stack demo web
podium start --stack demo web
podium restart --stack demo web
```

`metrics` emits Prometheus text with daemon uptime, per-service phase,
durable starts/restarts, last probe latency, and accepted relay connections.
A simple textfile collector can periodically redirect this command's output;
for remote stacks, add `--host` as described below.

`tui` opens an event-driven full-screen view with the live service table and
the selected service's latest log lines. Use `j`/`k` to select, `a` to start,
`s` to stop, `r` to restart, `l` to reload the stack, `u` to refresh, and `q`
to quit. It requires an interactive terminal; control actions use the same
audited RPCs as the ordinary commands.

Daemon logs are machine-parseable JSON lines with `timestamp`, `level`,
`stack`, and `message`. Current files and each numbered archive are capped at
10 MiB; three archives are retained. Service logs use human-readable
timestamps and the same size/archive limits.

## 8. Safe reloads and rolling updates

Edit the same file originally passed to `apply`, then preview and apply:

```sh
podium diff --stack demo
podium reload --stack demo
```

For a running, ready service whose published ports and dependency declaration
are unchanged, Podium starts a candidate, waits for its health check, retargets
the existing host listener, and only then stops the old VM. New connections
continue through the same host port. If candidate startup or health fails, the
reload returns an error and the old generation remains live.

Services without host ports, scheduled services, changed port/dependency
layouts, or services not currently ready use a conventional stop/start.

## 9. Backup and restore

For a consistent volume backup, stop the stack first. Preserve the stack file
and secret file separately from volume data:

```sh
podium down --stack demo
mkdir -p /path/to/backup/demo
ditto ~/.podium/demo/volumes /path/to/backup/demo/volumes
cp demo.json /path/to/backup/demo/
cp -p ~/.podium/demo/secrets.env /path/to/backup/demo/
```

Restore only while the stack is down:

```sh
mkdir -p ~/.podium/demo/volumes
ditto /path/to/backup/demo/volumes ~/.podium/demo/volumes
install -m 600 /path/to/backup/demo/secrets.env ~/.podium/demo/secrets.env
podium validate /path/to/backup/demo/demo.json
podium apply /path/to/backup/demo/demo.json
```

Application-aware database dumps are preferable to filesystem copies for
databases that cannot guarantee crash-consistent files.

## 10. Remote operation

The daemon must already be running on the remote Mac. Remote Login and normal
key-based SSH access are required:

```sh
podium ps --stack demo --host user@mac.example
podium logs --stack demo --host user@mac.example web -f
podium exec --stack demo --host user@mac.example web -- uname -a
podium metrics --stack demo --host user@mac.example
podium tui --stack demo --host user@mac.example
```

The client discovers the remote home directory, opens a local Unix-socket
forward to the remote gRPC socket, and reuses an SSH control master. `--host`
always requires an explicit `--stack`.

## 11. Persistence across login/reboot

Until Developer ID signing is available, Podium uses a localhost-SSH
LaunchAgent workaround: launchd cannot directly run the ad-hoc-signed binary
with its virtualization entitlement (AMFI kills it), but the same binary runs
when spawned through sshd. Create the one-time loopback key and enable Remote
Login:

```sh
ssh-keygen -t ed25519 -N "" -f ~/.ssh/podium_localhost
printf 'from="127.0.0.1,::1" %s\n' "$(cat ~/.ssh/podium_localhost.pub)" >> ~/.ssh/authorized_keys
```

Then install one configured stack from its checkout:

```sh
make install STACK=examples/stack.json
```

The LaunchAgent is user-scoped, requires a GUI login, and is labeled
`io.github.pgstr.podium` by default; pass `LABEL=<label>` to `install`,
`restart`, and `uninstall` to use a different one. Remove it with
`make uninstall`. The direct, no-SSH LaunchAgent path is documented in
[releasing.md](releasing.md) but remains deferred until a Developer ID
certificate is available.

## 12. Upgrade and rollback

Before upgrading, retain the currently installed executable and validate the
new checkout:

```sh
cp /usr/local/bin/podium /path/to/backup/podium.previous
make test
make build
./podium doctor
./podium validate /absolute/path/to/demo.json
make install-cli
```

An already-running daemon keeps its old executable image until restarted.
For a manually applied stack, use `podium down` and apply it with the new
binary. For the installed LaunchAgent, `make restart` installs and reloads it.
Confirm `ps`, `events`, logs, and application health after the restart.

To roll back, install the saved executable over `/usr/local/bin/podium`, then
restart the daemon in the same way. Podium refuses state written by a newer,
unsupported schema instead of guessing; keep a backup of `~/.podium` before a
version that announces a state-schema change.

## 13. Troubleshooting

Start with:

```sh
podium doctor
podium stacks
podium ps --stack demo
tail -n 100 ~/.podium/demo/daemon.log
```

Common cases:

- **Kernel or vminit FAIL:** run `make runtime-assets` while online, then rerun
  `doctor`.
- **Stale socket:** verify no daemon owns the stack, then run
  `podium stacks --prune`. Only `podium.sock` and `daemon.pid` are removed;
  volumes, logs, secrets, state, and the lock inode remain.
- **Stack already running:** use `reload` for a spec change or `down` before a
  new `apply`. Do not delete the lock file.
- **Service not ready:** inspect `describe`, service logs, and recent events;
  verify the health command works inside the guest with `exec`.
- **Published port unavailable:** inspect the `ps` ADDRESS column and daemon
  log for bind errors; check whether another host process owns the port.
- **Remote command fails:** pass both `--stack` and `--host`, verify SSH access,
  and confirm the remote daemon's `podium.sock` exists.
- **Disk growth:** `doctor` reports separate log and volume totals. Logs rotate
  automatically; volumes are operator-owned data and require an explicit
  retention or backup policy.

Never run `selftest` against production. The stack lock refuses this, but an
isolated stack name and disposable data remain mandatory for acceptance work.
