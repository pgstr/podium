import Foundation

public enum PodiumLogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

public struct StructuredLogRecord: Codable, Sendable {
    public let timestamp: Date
    public let level: PodiumLogLevel
    public let stack: String
    public let message: String

    public init(timestamp: Date, level: PodiumLogLevel, stack: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.stack = stack
        self.message = message
    }
}

public enum StructuredLogging {
    public static func level(for message: String) -> PodiumLogLevel {
        let lower = message.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("[fail]") {
            return .error
        }
        if lower.contains("warn") { return .warning }
        if lower.contains("[debug]") { return .debug }
        return .info
    }

    public static func line(
        message: String, stack: String, timestamp: Date = Date()
    ) throws -> Data {
        let record = StructuredLogRecord(
            timestamp: timestamp, level: level(for: message),
            stack: stack, message: message)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record) + Data([0x0a])
    }
}

/// Thread-safe bounded append-only file with numbered archives. An incoming
/// write may be split at the size boundary so no file can exceed `maxBytes`.
public final class RotatingLogSink: @unchecked Sendable {
    public let path: String
    public let maxBytes: UInt64
    public let archives: Int

    private let lock = NSLock()
    private var handle: FileHandle
    private var size: UInt64

    public init(path: String, maxBytes: UInt64, archives: Int) throws {
        self.path = path
        self.maxBytes = max(1, maxBytes)
        self.archives = max(0, archives)

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        size = (try? handle.seekToEnd()) ?? 0
        if size >= self.maxBytes {
            try rotateLocked()
        }
    }

    deinit { try? handle.close() }

    public func append(_ data: Data) throws {
        try lock.withLock {
            var offset = data.startIndex
            while offset < data.endIndex {
                if size >= maxBytes { try rotateLocked() }
                let capacity = Int(min(
                    maxBytes - size, UInt64(data.distance(from: offset, to: data.endIndex))))
                let end = data.index(offset, offsetBy: capacity)
                try handle.write(contentsOf: data[offset..<end])
                size += UInt64(capacity)
                offset = end
            }
        }
    }

    public func close() throws {
        try lock.withLock { try handle.synchronize() }
    }

    private func rotateLocked() throws {
        try handle.close()
        let fm = FileManager.default
        if archives > 0 {
            try? fm.removeItem(atPath: "\(path).\(archives)")
            if archives > 1 {
                for n in stride(from: archives - 1, through: 1, by: -1) {
                    let source = "\(path).\(n)"
                    if fm.fileExists(atPath: source) {
                        try? fm.moveItem(atPath: source, toPath: "\(path).\(n + 1)")
                    }
                }
            }
            if fm.fileExists(atPath: path) {
                try? fm.moveItem(atPath: path, toPath: "\(path).1")
            }
        } else {
            try? fm.removeItem(atPath: path)
        }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        size = 0
    }
}
