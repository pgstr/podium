// SSHTunnelPaths.swift — pure path math for the `--host` SSH tunnel.
//
// The CLI spawns ssh with a multiplexed master; this helper owns the *paths*
// so they can be unit-tested:
// the ControlMaster socket, the cached remote-home file, and the per-host tag
// that keeps ControlPath inside sun_path (~104 bytes on macOS).

import Foundation

public enum SSHTunnelPaths {
    /// Stable, short, filesystem-safe tag for an ssh target (`host` or
    /// `user@host`). FNV-1a — deterministic and dependency-free; it needs to be
    /// collision-resistant enough for a handful of hosts, not cryptographic.
    /// 16 hex chars, so `cm-<tag>.sock` is ~24 chars and ControlPath fits.
    public static func hostTag(_ host: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325            // FNV offset basis
        for byte in host.utf8 {
            h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3   // FNV prime
        }
        return String(format: "%016llx", h)
    }

    /// Directory holding all tunnel state (control sockets, home cache). 0700.
    public static func dir(home: String) -> String {
        "\(home)/.podium/ssh"
    }

    /// The `ControlPath` for the multiplexed master to `host`.
    public static func controlPath(home: String, host: String) -> String {
        "\(dir(home: home))/cm-\(hostTag(host)).sock"
    }

    /// Cache file for `host`'s remote `$HOME` (skips the probe on warm runs).
    public static func homeCache(home: String, host: String) -> String {
        "\(dir(home: home))/home-\(hostTag(host))"
    }

    /// Arguments appended to `ssh` when probing the remote user's home.
    /// Avoid `sh -c`: OpenSSH rejoins argv into a remote shell command, so
    /// `["sh", "-c", "echo $HOME"]` becomes `sh -c echo $HOME` and prints
    /// an empty line because `echo` is treated as the command string.
    public static func remoteHomeProbeArguments(host: String) -> [String] {
        [host, "printenv", "HOME"]
    }

    /// Control commands appended to the shared SSH options. Starting the
    /// master explicitly keeps per-command `-L` forwarders as disposable slave
    /// processes; otherwise the first forwarder can become the persistent
    /// master and leave its temporary socket forwards alive.
    public static func masterCheckArguments(host: String) -> [String] {
        ["-O", "check", host]
    }

    public static func masterStartArguments(host: String) -> [String] {
        ["-M", "-N", "-f", host]
    }
}
