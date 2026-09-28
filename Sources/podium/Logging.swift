import Containerization
import Darwin
import Foundation
import PodiumDaemon

/// Appends a container's stdout+stderr to ~/.podium/<stack>/logs/<id>.log so `podium logs`
/// can read (and follow) it. One instance is shared for stdout and stderr → merged.
///
/// Each complete line is written with a "[yyyy-MM-dd HH:mm:ss] " prefix so that
/// `podium logs --since <duration>` can filter by timestamp.
/// Partial lines (no trailing newline) are buffered until the newline arrives or
/// the writer is closed, at which point they are flushed with a timestamp.
final class FileLogWriter: Writer, @unchecked Sendable {
    private let sink: RotatingLogSink
    private var buf  = Data()
    private let lock = NSLock()
    private let redactor: SecretRedactor

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(path: String, redactions: [String] = []) throws {
        redactor = SecretRedactor(values: redactions)
        sink = try RotatingLogSink(path: path, maxBytes: 10 << 20, archives: 3)
    }

    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        buf.append(data)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex...nl]
            try writeLine(line)
            buf.removeSubrange(buf.startIndex...nl)
        }
    }

    func close() throws {
        lock.lock()
        if !buf.isEmpty {
            // Flush partial line — add a newline so the file stays clean.
            try? writeLine(buf + Data([0x0A]))
            buf.removeAll()
        }
        lock.unlock()
        try sink.close()
    }

    /// Write one complete line (including its trailing newline) with a timestamp prefix.
    private func writeLine(_ line: Data) throws {
        let ts = Self.formatter.string(from: Date())
        let prefix = Data("[\(ts)] ".utf8)
        try sink.append(prefix + redactor.redact(line))
    }
}

/// Converts the daemon's existing line-oriented output to bounded JSONL
/// without forcing every reconciler call site to know about log transport.
/// When foregrounded in a terminal, raw lines are also echoed to that terminal.
final class StructuredDaemonLogCapture: @unchecked Sendable {
    private let readFD: Int32
    private let sink: RotatingLogSink

    init(stackName: String) throws {
        sink = try RotatingLogSink(
            path: StackPaths.daemonLogPath(for: stackName),
            maxBytes: 10 << 20, archives: 3)

        let terminalFD = isatty(STDOUT_FILENO) == 1 ? dup(STDOUT_FILENO) : -1
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        readFD = descriptors[0]
        let writeFD = descriptors[1]
        fflush(stdout)
        fflush(stderr)
        guard dup2(writeFD, STDOUT_FILENO) >= 0,
              dup2(writeFD, STDERR_FILENO) >= 0 else {
            Darwin.close(readFD)
            Darwin.close(writeFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Darwin.close(writeFD)

        let readFD = self.readFD
        let sink = self.sink
        let thread = Thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 8_192)

            func emit(_ bytes: Data) {
                let raw = bytes.last == 0x0a ? bytes : bytes + Data([0x0a])
                if terminalFD >= 0 {
                    raw.withUnsafeBytes { ptr in
                        guard let base = ptr.baseAddress else { return }
                        var offset = 0
                        while offset < raw.count {
                            let count = Darwin.write(terminalFD, base + offset, raw.count - offset)
                            if count > 0 { offset += count; continue }
                            if count < 0 && errno == EINTR { continue }
                            break
                        }
                    }
                }
                let content = raw.last == 0x0a ? raw.dropLast() : raw[raw.startIndex...]
                let message = String(decoding: content, as: UTF8.self)
                if let line = try? StructuredLogging.line(message: message, stack: stackName) {
                    try? sink.append(line)
                }
            }

            while true {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count > 0 {
                    pending.append(contentsOf: buffer.prefix(Int(count)))
                    while let newline = pending.firstIndex(of: 0x0a) {
                        emit(Data(pending[pending.startIndex...newline]))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if !pending.isEmpty { emit(pending) }
                try? sink.close()
                if terminalFD >= 0 { Darwin.close(terminalFD) }
                Darwin.close(readFD)
                break
            }
        }
        thread.name = "podium-daemon-json-log"
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// Captures a process's output into memory for one-shot exec.
final class BufferWriter: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()
    func write(_ d: Data) throws { lock.lock(); data.append(d); lock.unlock() }
    func close() throws {}
}
