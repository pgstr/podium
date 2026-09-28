// Parsing.swift — small pure parsing/formatting helpers shared by the CLI and
// daemon.
import Foundation

/// Parse a compact duration string ("1h", "30m", "1h30m", "90s", "2d") into seconds.
/// Returns nil if the string is not a valid duration.
public func parseDuration(_ s: String) -> TimeInterval? {
    guard !s.isEmpty else { return nil }
    var total: TimeInterval = 0; var num = ""
    for ch in s {
        if ch.isNumber { num.append(ch) }
        else if let n = Double(num), !num.isEmpty {
            switch ch {
            case "d": total += n * 86400
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            num = ""
        } else { return nil }
    }
    return num.isEmpty ? total : nil  // trailing digits without a unit = invalid
}

/// Parsed positional portion of `podium exec` after global `--stack` and
/// `--host` options have been removed.
public struct ExecInvocation: Sendable, Equatable {
    public let service: String
    public let argv: [String]
    public let interactive: Bool

    public init(service: String, argv: [String], interactive: Bool) {
        self.service = service
        self.argv = argv
        self.interactive = interactive
    }
}

/// Parse `[-it | -i -t] <svc> [--] <cmd...>` without stealing flags that
/// belong to the command itself. The optional `--` matches the documented
/// CLI form and is not forwarded into the container.
public func parseExecInvocation(_ args: [String]) -> ExecInvocation? {
    var rest = args
    var stdin = false
    var tty = false

    while let first = rest.first {
        switch first {
        case "-it", "-ti": stdin = true; tty = true
        case "-i": stdin = true
        case "-t": tty = true
        default: break
        }
        guard first == "-it" || first == "-ti" || first == "-i" || first == "-t" else {
            break
        }
        rest.removeFirst()
    }

    guard !rest.isEmpty else { return nil }
    let service = rest.removeFirst()
    if rest.first == "--" { rest.removeFirst() }
    guard !service.isEmpty, !rest.isEmpty else { return nil }
    return ExecInvocation(service: service, argv: rest, interactive: stdin && tty)
}

/// Format a duration as a compact human-readable age string, e.g. "3d2h", "45m", "8s".
public func age(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    let m = s / 60; if m < 60 { return "\(m)m" }
    let h = m / 60; if h < 24 { return "\(h)h\(m % 60)m" }
    let d = h / 24; return "\(d)d\(h % 24)h"
}

/// Format a duration as "in Xm", "in 2h30m", etc. (for next-run display).
public func inDuration(_ date: Date, now: Date = Date()) -> String {
    let s = Int(date.timeIntervalSince(now))
    guard s > 0 else { return "now" }
    if s < 60 { return "in \(s)s" }
    let m = s / 60; if m < 60 { return "in \(m)m" }
    let h = m / 60; if h < 24 { return "in \(h)h\(m % 60 > 0 ? "\(m % 60)m" : "")" }
    let d = h / 24; return "in \(d)d\(h % 24 > 0 ? "\(h % 24)h" : "")"
}

// DateFormatter is documented thread-safe for formatting since macOS 10.9;
// the formatter is configured once and never mutated afterwards.
private let logTSFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// Parse the timestamp prefix of a podium log line ("[yyyy-MM-dd HH:mm:ss] ...").
/// Returns nil for lines without a parseable prefix (callers treat those as "keep").
public func parseLogTimestamp(_ line: String) -> Date? {
    guard line.count > 21, line.hasPrefix("[") else { return nil }
    let start = line.index(line.startIndex, offsetBy: 1)
    let end   = line.index(line.startIndex, offsetBy: 20)
    return logTSFormatter.date(from: String(line[start..<end]))
}
