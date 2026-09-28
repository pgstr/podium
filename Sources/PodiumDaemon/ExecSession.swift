// ExecSession.swift — the streaming exec seam.
//
// One live exec (interactive or not) as byte streams: stdin/resize go in,
// stdout/stderr/exit come out. The control plane's bidi Exec RPC drives this
// protocol; the Containerization adapter implements it over a pipe pair
// (non-tty) or a PTY (tty); tests drive scripted sessions on any platform.

import Foundation

/// One unit of exec output. `exit` is terminal: the session yields it last
/// and finishes its stream.
public enum ExecChunk: Sendable, Equatable {
    case stdout(Data)
    /// Non-tty only — a PTY merges stderr into the terminal stream.
    case stderr(Data)
    case exit(Int32)
}

/// A byte-bounded, back-pressuring stream of `ExecChunk`.
///
/// Consuming an element releases its bytes back to the producer, so a fast
/// process (a 500 MB `cat`, `head -c 500m /dev/zero`) can never outrun a
/// slow consumer: the daemon's buffer stays bounded instead of growing to
/// the entire output.
///
/// It's a thin wrapper over `AsyncStream`, so the consumer still just
/// `for await`s it. Producers that already pace themselves (scripted test
/// sessions) use `makeStream()`; runtime adapters that pull from a pipe/PTY
/// as fast as the kernel allows use `makeBackpressured(capacityBytes:)`.
public struct ExecOutput: AsyncSequence, Sendable {
    public typealias Element = ExecChunk
    private let stream: AsyncStream<ExecChunk>
    private let onConsume: @Sendable (ExecChunk) -> Void

    init(stream: AsyncStream<ExecChunk>, onConsume: @escaping @Sendable (ExecChunk) -> Void) {
        self.stream = stream
        self.onConsume = onConsume
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: stream.makeAsyncIterator(), onConsume: onConsume)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var inner: AsyncStream<ExecChunk>.AsyncIterator
        let onConsume: @Sendable (ExecChunk) -> Void
        public mutating func next() async -> ExecChunk? {
            let c = await inner.next()
            if let c { onConsume(c) }   // freed on consumption, not on arrival
            return c
        }
    }

    /// Unbounded, no back-pressure. Mirrors `AsyncStream.makeStream` — for
    /// scripted/test sessions and any producer that already self-paces.
    public static func makeStream() -> (ExecOutput, AsyncStream<ExecChunk>.Continuation) {
        let (s, c) = AsyncStream.makeStream(of: ExecChunk.self, bufferingPolicy: .unbounded)
        return (ExecOutput(stream: s, onConsume: { _ in }), c)
    }

    /// Byte-bounded with a blocking sink. `sink.write` blocks its caller
    /// whenever `capacityBytes` of unconsumed output is outstanding, which
    /// back-pressures through the runtime all the way to the container.
    public static func makeBackpressured(capacityBytes: Int) -> (ExecOutput, ExecOutputSink) {
        let (s, c) = AsyncStream.makeStream(of: ExecChunk.self, bufferingPolicy: .unbounded)
        let sink = ExecOutputSink(continuation: c, capacityBytes: capacityBytes)
        return (ExecOutput(stream: s, onConsume: { sink.release($0) }), sink)
    }
}

/// Producer side of a back-pressured `ExecOutput`. `write` is synchronous and
/// blocks the calling thread — feed it from the runtime's stdout/stderr I/O
/// thread (a pipe reader or Containerization writer), never an async context.
public final class ExecOutputSink: @unchecked Sendable {
    private let cont: AsyncStream<ExecChunk>.Continuation
    private let cap: Int
    private let cond = NSCondition()
    private var inFlight = 0
    private var closed = false

    init(continuation: AsyncStream<ExecChunk>.Continuation, capacityBytes: Int) {
        self.cont = continuation
        self.cap = max(capacityBytes, 1)
    }

    private static func bytes(of chunk: ExecChunk) -> Int {
        switch chunk {
        case .stdout(let d), .stderr(let d): return d.count
        case .exit: return 0
        }
    }

    /// Enqueue a chunk, blocking while the buffer is full. The terminal
    /// `.exit` (zero bytes) never blocks, so it always lands last. After
    /// `finish()`, writes are dropped rather than blocking forever.
    public func write(_ chunk: ExecChunk) {
        let n = Self.bytes(of: chunk)
        cond.lock()
        while inFlight >= cap && !closed && n > 0 { cond.wait() }
        if closed { cond.unlock(); return }
        inFlight += n
        cond.unlock()
        cont.yield(chunk)
    }

    /// The consumer took a chunk — free its bytes and wake a blocked writer.
    fileprivate func release(_ chunk: ExecChunk) {
        cond.lock()
        inFlight -= Self.bytes(of: chunk)
        cond.signal()
        cond.unlock()
    }

    /// End the stream and wake any blocked writer (which then drops its
    /// chunk). Idempotent — safe on both the clean exit and terminate paths.
    public func finish() {
        cond.lock()
        if closed { cond.unlock(); return }
        closed = true
        cond.broadcast()
        cond.unlock()
        cont.finish()
    }
}

/// A live exec session. All methods are safe to call after the process
/// exited (they become no-ops) — the RPC layer races client input against
/// process exit by design.
public protocol ExecSession: Sendable {
    /// stdout/stderr chunks, then exactly one `.exit`, then finish.
    var output: ExecOutput { get }
    /// Feed bytes to the process (PTY master for tty sessions).
    func writeStdin(_ data: Data) async
    /// No more stdin — lets non-tty processes reading stdin see EOF.
    func stdinEOF() async
    /// Window-size change (tty sessions; no-op otherwise).
    func resize(rows: UInt16, cols: UInt16) async
    /// Tear down early (client vanished mid-session). Idempotent.
    func terminate() async
}

/// Thrown by the default `startExecSession` for runtimes that haven't
/// wired streaming exec yet.
public struct ExecUnsupportedError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "streaming exec not supported by this runtime" }
}
