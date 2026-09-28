import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runtime seam for secret stores. The file-backed implementation is the
/// default; a future Keychain provider can implement the same contract.
public protocol SecretsProvider: Sendable {
    func value(for key: String) throws -> String
}

/// Reads secrets from the current stack's private file. The file is opened
/// without following symlinks, then checked before any bytes are parsed.
public struct FileSecretsProvider: SecretsProvider, Sendable {
    public let path: String
    private let expectedOwnerID: uid_t

    public init(stackName: String) {
        self.init(path: StackPaths.secretsPath(for: stackName), expectedOwnerID: getuid())
    }

    init(path: String, expectedOwnerID: uid_t) {
        self.path = path
        self.expectedOwnerID = expectedOwnerID
    }

    public func value(for key: String) throws -> String {
        let values = try load()
        guard let value = values[key] else {
            throw SecretError.missing(key: key, path: path)
        }
        return value
    }

    private func load() throws -> [String: String] {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw SecretError.unreadable(path: path, reason: errnoDescription())
        }
        defer { _ = close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw SecretError.unreadable(path: path, reason: errnoDescription())
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw SecretError.notRegular(path: path)
        }
        guard info.st_uid == expectedOwnerID else {
            throw SecretError.wrongOwner(
                path: path, expected: expectedOwnerID, actual: info.st_uid)
        }
        let permissions = info.st_mode & mode_t(0o777)
        guard permissions == mode_t(0o600) else {
            throw SecretError.insecurePermissions(path: path, actual: permissions)
        }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw SecretError.unreadable(path: path, reason: errnoDescription())
            }
            bytes.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SecretError.invalidUTF8(path: path)
        }

        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    private func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}

public enum SecretError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case notRegular(path: String)
    case wrongOwner(path: String, expected: uid_t, actual: uid_t)
    case insecurePermissions(path: String, actual: mode_t)
    case invalidUTF8(path: String)
    case missing(key: String, path: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            return "cannot read secrets file \(path): \(reason)"
        case let .notRegular(path):
            return "secrets file \(path) is not a regular file"
        case let .wrongOwner(path, expected, actual):
            return "secrets file \(path) is owned by uid \(actual), expected uid \(expected)"
        case let .insecurePermissions(path, actual):
            return "secrets file \(path) has mode \(Self.octal(actual)); expected 0600"
        case let .invalidUTF8(path):
            return "secrets file \(path) is not valid UTF-8"
        case let .missing(key, path):
            return "secret '\(key)' not found in \(path)"
        }
    }

    private static func octal(_ mode: mode_t) -> String {
        String(format: "%04o", mode)
    }
}

/// Replaces known secret byte sequences without requiring UTF-8. Callers pass
/// complete log lines, so a secret split across runtime write chunks is still
/// removed after the line buffer is assembled.
public struct SecretRedactor: Sendable {
    private static let replacement = Data("[REDACTED]".utf8)
    private let needles: [Data]

    public init(values: [String]) {
        needles = Set(values.filter { !$0.isEmpty })
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
            .map { Data($0.utf8) }
    }

    public func redact(_ data: Data) -> Data {
        var output = data
        for needle in needles {
            while let range = output.range(of: needle) {
                output.replaceSubrange(range, with: Self.replacement)
            }
        }
        return output
    }

    public func redact(_ text: String) -> String {
        String(decoding: redact(Data(text.utf8)), as: UTF8.self)
    }
}
