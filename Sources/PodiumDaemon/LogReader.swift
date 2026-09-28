// LogReader.swift — bounded-window log reads for the Logs stream.
//
// The daemon serves log bytes over the control plane so `logs` behaves
// identically local and remote. Invariant: nothing here ever loads a whole
// file — tail seeks backward block-by-block and stops at the window start
// (O(tail)); everything else streams forward in blocks. `since` filters
// line-granularly and keeps lines without a timestamp.

import Foundation
import PodiumCore

public enum LogReaderError: Error, CustomStringConvertible {
    case cannotOpen(String)
    public var description: String {
        switch self {
        case .cannotOpen(let p): return "cannot open \(p)"
        }
    }
}

public enum LogReader {

    public static let blockSize = 64 * 1024

    /// One stream for every mode:
    ///   tail > 0                → start at the last-`tail`-lines offset
    ///   sinceCutoff != nil      → start at 0, line-filter (tail is ignored)
    ///   follow                  → after EOF, poll for growth; a shrunk file
    ///                             (rotation) resets to offset 0
    /// Chunks are ≤ blockSize; the stream finishes at EOF unless following.
    public static func stream(
        path: String, tail: Int, sinceCutoff: Date?, follow: Bool, pollMs: Int = 200
    ) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let task = Task {
            do {
                guard let h = FileHandle(forReadingAtPath: path) else {
                    throw LogReaderError.cannotOpen(path)
                }
                defer { try? h.close() }

                var offset: UInt64 = 0
                if sinceCutoff == nil, tail > 0 {
                    offset = try tailStartOffset(handle: h, tail: tail)
                }
                var carry = Data()   // partial line between blocks (since mode)

                while true {
                    try Task.checkCancellation()
                    let size = try h.seekToEnd()
                    if size < offset {           // rotated/truncated under us
                        offset = 0
                        carry.removeAll()
                    }
                    if offset < size {
                        try h.seek(toOffset: offset)
                        while offset < size {
                            try Task.checkCancellation()
                            let want = Int(min(UInt64(blockSize), size - offset))
                            guard let block = try h.read(upToCount: want), !block.isEmpty else { break }
                            offset += UInt64(block.count)
                            if let cutoff = sinceCutoff {
                                let out = filterLines(carry: &carry, incoming: block, cutoff: cutoff)
                                if !out.isEmpty { continuation.yield(out) }
                            } else {
                                continuation.yield(block)
                            }
                        }
                    }
                    if !follow { break }
                    try await Task.sleep(for: .milliseconds(pollMs))
                }
                // A final line without trailing newline is still a line —
                // filter it and emit newline-terminated.
                if sinceCutoff != nil, !carry.isEmpty,
                   linePasses(carry, cutoff: sinceCutoff!) {
                    continuation.yield(carry + Data([0x0A]))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Offset of the first byte of the last `tail` lines. Scans backward in
    /// blocks and stops as soon as enough newlines are seen — the file size
    /// never matters, only the window does.
    static func tailStartOffset(handle h: FileHandle, tail: Int) throws -> UInt64 {
        let size = try h.seekToEnd()
        guard size > 0, tail > 0 else { return 0 }
        var pos = size
        var newlines = 0
        var sawTrailingTerminator = false
        while pos > 0 {
            let want = Int(min(UInt64(blockSize), pos))
            let blockStart = pos - UInt64(want)
            try h.seek(toOffset: blockStart)
            guard let block = try h.read(upToCount: want), !block.isEmpty else { break }
            var i = block.count - 1
            while i >= 0 {
                if block[i] == 0x0A {
                    if !sawTrailingTerminator, blockStart + UInt64(i) == size - 1 {
                        // The file's final newline terminates the last line;
                        // it doesn't start a new one.
                        sawTrailingTerminator = true
                    } else {
                        newlines += 1
                        if newlines == tail { return blockStart + UInt64(i) + 1 }
                    }
                }
                i -= 1
            }
            pos = blockStart
        }
        return 0   // fewer than `tail` lines — whole file
    }

    /// Filter complete lines in carry+incoming; the trailing partial line
    /// stays in `carry`. Passing lines are emitted with their newline.
    private static func filterLines(carry: inout Data, incoming: Data, cutoff: Date) -> Data {
        var buf = carry
        buf.append(incoming)
        var out = Data()
        var lineStart = buf.startIndex
        var i = buf.startIndex
        while i < buf.endIndex {
            if buf[i] == 0x0A {
                let line = buf[lineStart..<i]
                if linePasses(line, cutoff: cutoff) {
                    out.append(buf[lineStart...i])   // line incl. newline
                }
                lineStart = buf.index(after: i)
            }
            i = buf.index(after: i)
        }
        carry = Data(buf[lineStart...])
        return out
    }

    /// Unparseable prefix = keep.
    private static func linePasses(_ line: Data, cutoff: Date) -> Bool {
        // Timestamp prefix is ASCII and 22 bytes ("[yyyy-MM-dd HH:mm:ss] ");
        // decode only that much.
        let head = String(decoding: line.prefix(22), as: UTF8.self)
        guard let ts = parseLogTimestamp(head) else { return true }
        return ts >= cutoff
    }
}
