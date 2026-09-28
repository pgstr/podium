# Podium

[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black)](docs/compatibility.md)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**Run your containers on a Mac, and keep them running.**

Podium is a small container orchestrator for Apple-silicon Macs. You describe
your services in one file (Podium's JSON format or a Docker Compose file), run
`podium apply`, and Podium starts each container in its own lightweight Linux
VM using Apple's [Containerization](https://github.com/apple/containerization)
framework. It then keeps watching: crashed services get restarted, unhealthy
ones get replaced, and the whole stack comes back on its own after a crash or
a reboot.

Think of it as `docker compose` plus a supervisor that never sleeps, built
natively for macOS. No Docker Desktop, no Kubernetes, no background VM you have
to babysit.

## Who is it for?

Podium is for anyone with a Mac that runs a handful of long-lived services:

- a Mac mini home server running your self-hosted apps,
- a development machine that needs a database, a cache, and a few helpers,
- a small always-on box for bots, scheduled jobs, or internal tools.

If you need many machines, you want Kubernetes. If you have one Mac and want
your containers to just stay up, Podium is meant for you.

## A quick look

Here's a small stack: a web server, a Redis cache it depends on, and a nightly
backup job.

```json
{
  "name": "shop",
  "services": [
    {
      "id": "cache",
      "image": "docker.io/library/redis:7-alpine",
      "healthCheck": ["redis-cli", "ping"]
    },
    {
      "id": "web",
      "image": "docker.io/library/nginx:1.27-alpine",
      "dependsOn": ["cache"],
      "healthCheck": ["wget", "-q", "-O-", "http://127.0.0.1"],
      "ports": [{"hostPort": 8080, "containerPort": 80}]
    },
    {
      "id": "backup",
      "image": "docker.io/library/redis:7-alpine",
      "schedule": "0 3 * * *",
      "command": ["sh", "-c", "redis-cli -h cache --rdb /backups/dump-$(date +%F).rdb"],
      "volumes": [{"name": "backups", "destination": "/backups"}]
    }
  ]
}
```

Bring it up and look around:

```console
$ podium apply shop.json
$ podium ps --stack shop
$ curl http://127.0.0.1:8080
$ podium logs --stack shop web -f
```

Podium starts `cache` first, waits until `redis-cli ping` succeeds, then starts
`web`. It publishes port 8080 on localhost and runs `backup` every night at
03:00. If `web` crashes, it is restarted with a growing delay. If it keeps
crashing, Podium stops retrying, marks it `failed`, and tells you why.

## Features

**It heals itself.** Every service has a restart policy and an exponential
backoff. Liveness checks catch services that are running but stuck. A service
that crash-loops is marked `failed` with a reason instead of restarting
forever.

**It survives crashes and reboots.** Podium writes its state to disk before it
acts. If the supervisor itself is killed, the next start cleans up leftover VMs
and brings the stack back where it was. A LaunchAgent can start the stack
automatically at login.

**Startup order that means something.** `dependsOn` waits for a dependency to
pass its health check, not just to start. Services with no dependencies on
each other start in parallel.

**Updates without downtime.** Edit your stack file and run `podium diff` to
preview the change, then `podium reload`. For services with published ports,
Podium starts the new version next to the old one, waits for it to become
healthy, switches traffic over, and only then stops the old one. If the new
version fails its health check, the old one keeps serving.

**Bring your Compose files.** Most Docker Compose files work as they are:
images, commands, environment and `env_file`, volumes, `depends_on`, health
checks, restart policies, resource limits, and ports. Anything Podium can't
map, like `build` or `networks`, produces a clear warning. `podium migrate`
shows you the translated result.

**Scheduled jobs.** Give a service a cron `schedule` and it runs as a one-shot
job at those times, with its last run and exit code shown in `podium ps`.

**Safe defaults.** Published ports listen only on `127.0.0.1` unless you
explicitly ask for more. Secrets live in a private per-stack file, are injected
as environment variables, and are scrubbed from logs and events. `podium down`
never deletes your data unless you add `--volumes`.

**Networking that helps.** Services find each other by name. Turn on
`"dns": true` for a stack-local DNS server that follows services as they move,
or add an `ingress` block to get a managed Caddy reverse proxy that routes
hostnames to your services.

**Everything you need day to day.** Follow logs, run a shell inside a
container, copy files in and out, watch live CPU and memory, stream events, or
open an interactive dashboard in your terminal.

**Works from another machine.** Add `--host user@your-mac` to any command to
control a stack over SSH, with the same commands and output as locally.

## Getting started

### Requirements

- An Apple-silicon Mac running **macOS 26** or newer
- **Swift 6.2+** with the macOS 26 SDK (Xcode 26 or the matching toolchain)
- Apple's [`container`](https://github.com/apple/container) tool, installed
  once so a compatible Linux kernel is available

See [Runtime compatibility](docs/compatibility.md) for the exact tested
versions.

### Install

```sh
git clone https://github.com/pgstr/podium.git
cd podium
make install-cli
podium doctor
```

`make install-cli` builds Podium, prepares its runtime (the Linux kernel and
the matching guest init image), and installs the `podium` command to
`/usr/local/bin`. It asks for your password only to copy the binary. `podium
doctor` checks that everything is in place and tells you how to fix anything
that isn't.

After this one-time setup, Podium doesn't need the `container` CLI or network
access to start. Images still need to be pulled or loaded once.

### Your first stack

Save this as `hello.json`:

```json
{
  "name": "hello",
  "services": [
    {
      "id": "web",
      "image": "docker.io/library/busybox:1.37",
      "command": ["/bin/sh", "-c",
        "mkdir -p /www; echo 'Hello from Podium' > /www/index.html; exec busybox httpd -f -p 8080 -h /www"],
      "healthCheck": ["wget", "-q", "-O-", "http://127.0.0.1:8080"],
      "ports": [8080]
    }
  ]
}
```

Then:

```sh
podium validate hello.json     # check the file without starting anything
podium apply hello.json        # start the stack in the background
podium ps --stack hello        # see what's running
curl http://127.0.0.1:8080     # → Hello from Podium
podium down --stack hello      # stop it again (data is kept)
```

Prefer Compose? Try `podium apply examples/compose.yml`. The
[`examples/`](examples) folder also covers dependencies, cron jobs, secrets,
volumes, DNS, and ingress.

## Configuration

A stack is a `name` plus a list of `services`. Only `id` and `image` are
required; everything else is optional.

| Field | What it's for | Example |
|---|---|---|
| `command`, `entrypoint`, `args` | Override the image's process | `"command": ["redis-server", "--save", "60 1"]` |
| `env` | Environment variables | `"env": {"LOG_LEVEL": "info"}` |
| `secrets` | Env vars filled from the stack's secret file | `"secrets": {"API_TOKEN": "WEB_TOKEN"}` |
| `ports` | Publish container ports on the host | `"ports": [8080, {"hostPort": 8443, "containerPort": 443}]` |
| `volumes` | Host folders or Podium-managed volumes | `"volumes": [{"name": "data", "destination": "/data"}]` |
| `dependsOn` | Start only after these services are healthy | `"dependsOn": ["db"]` |
| `healthCheck` | Command that exits 0 when the service is ready | `"healthCheck": ["pg_isready"]` |
| `livenessCheck` | Command that keeps checking it stays healthy | `"livenessCheck": ["pgrep", "nginx"]` |
| `restartPolicy` | `always` (default), `on-failure`, or `no` | `"restartPolicy": "on-failure"` |
| `schedule` | Run as a cron job instead of a long-lived service | `"schedule": "*/15 * * * *"` |
| `init` | One-shot setup steps before the main container | `"init": [{"command": ["sh", "-c", "mkdir -p /data/cache"]}]` |
| `cpus`, `memoryMB`, `rootfsGB` | VM resources | `"cpus": 2, "memoryMB": 1024` |

**Secrets** go in `~/.podium/<stack>/secrets.env`, a plain `KEY=value` file
that must be readable only by you (`chmod 600`):

```sh
mkdir -p ~/.podium/shop
printf 'WEB_TOKEN=change-me\n' > ~/.podium/shop/secrets.env
chmod 600 ~/.podium/shop/secrets.env
```

**Compose files** work directly. This is the same shop stack from above as
Compose:

```yaml
name: shop

services:
  cache:
    image: docker.io/library/redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]

  web:
    image: docker.io/library/nginx:1.27-alpine
    depends_on:
      cache:
        condition: service_healthy
    ports:
      - "8080:80"   # localhost only; add `x-podium: {publish: true}` for all interfaces
```

**Stack-level options** turn on networking helpers:

```json
{
  "name": "shop",
  "dns": true,
  "ingress": {
    "hostPort": 8088,
    "routes": [{"host": "shop.home.arpa", "service": "web", "port": 80}]
  },
  "services": [ ... ]
}
```

`dns` gives services a resolver that tracks their addresses as they restart.
`ingress` runs a managed Caddy proxy on `127.0.0.1:8088` that routes each
hostname to a service. The full schema is in the
[Operator guide](docs/operator-guide.md#4-stack-schema-essentials).

## Usage

### Run and change a stack

| Command | What it does |
|---|---|
| `podium apply <file>` | Start a stack from a JSON or Compose file and supervise it |
| `podium diff --stack <name>` | Show what a reload would change |
| `podium reload --stack <name>` | Apply your edited stack file to the running stack |
| `podium stop \| start \| restart --stack <name> <svc>` | Control a single service |
| `podium down --stack <name> [--volumes]` | Stop the stack; `--volumes` also deletes its data |

### See what's going on

| Command | What it does |
|---|---|
| `podium stacks` | List all stacks on this Mac |
| `podium ps --stack <name>` | Service table with state, readiness, restarts, and addresses |
| `podium describe --stack <name> <svc>` | Full configuration and status of one service |
| `podium logs --stack <name> <svc> [-f] [--tail N] [--since 1h]` | Service logs, optionally followed |
| `podium events --stack <name> [-f]` | Everything that happened, in order |
| `podium top --stack <name>` | Live CPU and memory per service |
| `podium tui --stack <name>` | Interactive dashboard with logs and start/stop/restart keys |
| `podium metrics --stack <name>` | Prometheus-format metrics |

### Get hands-on

| Command | What it does |
|---|---|
| `podium exec --stack <name> -it <svc> /bin/sh` | Open a shell inside a running container |
| `podium cp --stack <name> <svc>:/path ./local` | Copy files out of (or into) a container |
| `podium pull <image>` / `podium load <image.tar>` / `podium images` | Manage the local image store |
| `podium validate <file>` / `podium migrate <compose.yml>` | Check a file, or translate Compose to native JSON |
| `podium doctor` | Diagnose the host and runtime |

Add `--host user@host` to any command that takes `--stack` to run it against
another Mac over SSH. Run `podium` without arguments for the full list.

### Keep it running across reboots

`make install STACK=path/to/stack.json` installs a LaunchAgent that starts the
stack when you log in and restarts the supervisor if it ever exits. See the
[Operator guide](docs/operator-guide.md#11-persistence-across-loginreboot) for
the one-time setup.

## How it works

Each stack gets its own supervisor process and its own private network. The
supervisor compares what your stack file asks for with what is actually
running and fixes the difference: it starts missing services, restarts crashed
ones, and stops removed ones. Every change is written to disk first, so the
supervisor can always pick up where it left off.

The CLI talks to the supervisor over a private, owner-only Unix socket using
gRPC. That same channel carries streaming logs, interactive shells, and file
copies, and it can be tunneled over SSH. All state lives in plain files below
`~/.podium/<stack>/`.

The details are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Current status

Podium is young but used for real, always-on workloads. A few things to know:

- It runs only on Apple-silicon Macs with macOS 26 or newer.
- You build it from source; there are no signed binaries or Homebrew package
  yet, because those require an Apple Developer ID.
- Without a Developer ID signature, launchd can't start Podium directly. The
  LaunchAgent therefore goes through a localhost SSH connection, which needs
  Remote Login enabled. The [Operator guide](docs/operator-guide.md) explains
  the setup.
- Compose support covers common fields, not the whole specification.

## Documentation

- [Operator guide](docs/operator-guide.md): installation, the stack format,
  secrets, reloads, backups, remote use, upgrades, and troubleshooting
- [Developer guide](docs/developer-guide.md): building, testing, and the rules
  the code relies on
- [Architecture](ARCHITECTURE.md): how the state model and control plane work
- [Runtime compatibility](docs/compatibility.md): supported and tested
  versions
- [Releasing](docs/releasing.md): signing and notarization

## Contributing

Bug reports, fixes, documentation improvements, and compatibility reports are
all welcome. Before opening a pull request, please:

1. keep the change focused and describe the behavior it changes,
2. add or update tests for behavior changes,
3. run `make test`, and
4. update the docs if commands, the stack format, or compatibility change.

Please don't include credentials, stack secrets, private logs, or host details
in public issues.

## License

Podium is licensed under the [Apache License 2.0](LICENSE). See
[NOTICE](NOTICE) for attribution.
