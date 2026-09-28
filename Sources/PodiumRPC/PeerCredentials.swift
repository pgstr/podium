// PeerCredentials.swift — who is on the other end of an AF_UNIX socket.
//
// The control socket only serves its owner: ControlPlaneServer checks the
// peer uid of every accepted connection against the daemon's uid and drops
// mismatches before a single HTTP/2 byte is parsed. Socket file perms
// (0600 in a 0700 dir) are the first line of defense; this check is the
// second, and the one that holds if the perms are ever loosened by hand.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum PeerCredentialsError: Error, CustomStringConvertible, Equatable {
    case getsockoptFailed(errno: Int32)

    public var description: String {
        switch self {
        case .getsockoptFailed(let err):
            return "cannot read peer credentials: \(String(cString: strerror(err)))"
        }
    }
}

#if canImport(Glibc)
/// Mirror of Glibc's `struct ucred` (pid_t/uid_t/gid_t, all 32-bit). Glibc
/// only exposes the real one under _GNU_SOURCE, which Swift's Glibc module
/// doesn't define — the kernel ABI is what SO_PEERCRED fills either way.
public struct LinuxUcred: Sendable {
    public var pid: Int32 = 0
    public var uid: UInt32 = 0
    public var gid: UInt32 = 0
    public init() {}
}
#endif

public enum PeerCredentials {
    /// The uid of the peer connected on `fd` (an AF_UNIX stream socket).
    ///
    /// Linux: `getsockopt(SO_PEERCRED)`; macOS: `getpeereid(2)`. Both report
    /// the credentials the peer held at `connect()` time, checked in-kernel —
    /// the peer cannot forge them.
    public static func peerUID(of fd: Int32) throws -> uid_t {
        #if canImport(Glibc)
        var cred = LinuxUcred()
        var len = socklen_t(MemoryLayout<LinuxUcred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 else {
            throw PeerCredentialsError.getsockoptFailed(errno: errno)
        }
        return cred.uid
        #else
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw PeerCredentialsError.getsockoptFailed(errno: errno)
        }
        return uid
        #endif
    }
}
