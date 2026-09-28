import Foundation

public enum DoctorStatus: String, Codable, Sendable {
    case pass = "PASS"
    case warning = "WARN"
    case fail = "FAIL"
}

public struct DoctorCheck: Codable, Sendable, Equatable {
    public let name: String
    public let status: DoctorStatus
    public let detail: String
    public let remediation: String?

    public init(name: String, status: DoctorStatus, detail: String,
                remediation: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.remediation = remediation
    }
}

public struct DoctorReport: Codable, Sendable, Equatable {
    public let checks: [DoctorCheck]
    public init(checks: [DoctorCheck]) { self.checks = checks }
    public var hasFailures: Bool { checks.contains { $0.status == .fail } }

    public func rendered() -> String {
        checks.flatMap { check -> [String] in
            var lines = ["[\(check.status.rawValue)] \(check.name) — \(check.detail)"]
            if let remediation = check.remediation {
                lines.append("       fix: \(remediation)")
            }
            return lines
        }.joined(separator: "\n")
    }
}

public enum DoctorExecutablePath {
    public static func resolve(
        argv0: String,
        bundleExecutableURL: URL? = Bundle.main.executableURL
    ) -> String {
        (bundleExecutableURL ?? URL(fileURLWithPath: argv0)).standardizedFileURL.path
    }
}

/// Removes only ephemeral evidence of a dead daemon. Durable state, service
/// logs, secrets, and managed volumes are deliberately outside this list.
public enum StaleStackFiles {
    public static let removable = ["podium.sock", "daemon.pid"]

    @discardableResult
    public static func prune(directory: URL) throws -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in removable {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
            removed.append(name)
        }
        return removed
    }
}
