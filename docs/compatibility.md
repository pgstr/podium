# Runtime compatibility

Podium deliberately pins its host library and guest init agent as one tested
runtime unit. They are not inferred from the separately installed Apple
`container` CLI.

| Component | Supported / pinned | Verified in this repository |
|---|---|---|
| Host architecture | Apple silicon (`arm64`) | Apple silicon |
| macOS | 26 or newer | 26.5 and 26.5.2 |
| Build toolchain | Swift 6.2+ with the macOS 26 SDK | Swift 6.3.2 and 6.3.3 |
| `apple/containerization` host library | exactly 0.46.0 | `Package.swift` and `Package.resolved`; unit suite only — Mac acceptance pending |
| `vminit` guest agent | exactly 0.46.0 | `ghcr.io/apple/containerization/vminit:0.46.0` |
| Linux kernel | Apple-container-compatible arm64 kernel | `vmlinux-6.18.15-186` |

Apple's upstream projects support Apple silicon and macOS 26; older macOS
versions are outside Podium's support boundary. See the official
[`apple/containerization` requirements](https://github.com/apple/containerization#requirements)
and [`apple/container` requirements](https://github.com/apple/container#requirements).

## Why the versions are exact

The Swift host library talks to `vminit` over a guest RPC interface. Podium
therefore uses an exact 0.46.0 package pin and materializes the matching 0.46.0
guest filesystem. The version of the separately installed `container` CLI
does not select Podium's linked library or its vminit image.

When upgrading Containerization, change the exact dependency and
`containerizationVersion` together, resolve packages, rebuild, then run the
full suite and Mac acceptance tests. The versioned init filesystem path keeps
the old and new guests separate.

## Container security defaults (0.46.0)

Releases after 0.35.0 start containers with the restricted OCI
capability baseline (the Docker default set: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`,
`FSETID`, `KILL`, `MKNOD`, `NET_BIND_SERVICE`, `NET_RAW`, `SETFCAP`, `SETGID`,
`SETPCAP`, `SETUID`, `SYS_CHROOT`, `AUDIT_WRITE`) plus the OCI standard masked
and read-only paths. Podium has no per-service capability field and inherits
this baseline. A workload that needs more, such as `NET_ADMIN` or `SYS_ADMIN`,
will fail under 0.46.0.

## Installation and offline startup

`make runtime-assets` performs the network-dependent preparation step:

1. builds and signs the Podium binary;
2. copies the newest installed Apple `container` kernel to
   `~/.podium/vmlinux`;
3. fetches and materializes the matching vminit filesystem in Podium's image
   store, with an atomic ready marker.

`make install-cli` and `make install` run that target automatically. Once it
has succeeded, daemon startup does not contact GHCR for vminit and does not
need the `container` CLI on `PATH`. Service images must still be present in
Podium's store (`podium pull` or `podium load`) if the host will start them
without network access.

The preparation step is idempotent. Run it again after a Containerization
upgrade or after deleting Podium's image store.
