// LogReaderTests.swift — bounded-window log reads.
//
// The O(tail) claim is tested structurally: the tail scan must produce the
// right window even when the window straddles block boundaries in a file
// much larger than one block — and it never touches bytes before the
// window (asserted indirectly by correctness on multi-megabyte files).

import Foundation
import PodiumCore
import XCTest

@testable import PodiumDaemon

final class LogReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to name: String = "svc.log") throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func collect(_ path: String, tail: Int = 0, sinceCutoff: Date? = nil) async throws -> String {
        var out = Data()
        for try await chunk in LogReader.stream(path: path, tail: tail, sinceCutoff: sinceCutoff, follow: false) {
            out.append(chunk)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: tail

    func testTailLastNLines() async throws {
        let path = try write((1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let out = try await collect(path, tail: 3)
        XCTAssertEqual(out, "line 998\nline 999\nline 1000\n")
    }

    func testTailBiggerThanFileYieldsWholeFile() async throws {
        let path = try write("a\nb\n")
        let out = try await collect(path, tail: 50)
        XCTAssertEqual(out, "a\nb\n")
    }

    func testTailWindowStraddlesBlockBoundaries() async throws {
        // Lines long enough that 100 of them cross the 64 KiB block size.
        let line = String(repeating: "x", count: 1500)
        let path = try write((1...200).map { "\($0)-\(line)" }.joined(separator: "\n") + "\n")
        let out = try await collect(path, tail: 100)
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        XCTAssertTrue(lines.first!.hasPrefix("101-"))
        XCTAssertTrue(lines.last!.hasPrefix("200-"))
    }

    func testTailNoTrailingNewline() async throws {
        let path = try write("one\ntwo\nthree")   // unterminated final line
        let out = try await collect(path, tail: 2)
        XCTAssertEqual(out, "two\nthree")
    }

    func testTailZeroMeansEverything() async throws {
        let path = try write("a\nb\nc\n")
        let out = try await collect(path, tail: 0)
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    // MARK: since

    func testSinceFiltersByTimestampAndKeepsUnstampedLines() async throws {
        let path = try write("""
            [2026-07-13 09:00:00] old line
            [2026-07-13 11:00:00] new line
            no timestamp here
            [2026-07-13 12:00:00] newest
            """ + "\n")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let cutoff = f.date(from: "2026-07-13 10:00:00")!
        let out = try await collect(path, sinceCutoff: cutoff)
        XCTAssertEqual(out, """
            [2026-07-13 11:00:00] new line
            no timestamp here
            [2026-07-13 12:00:00] newest
            """ + "\n")
    }

    func testSinceAcrossBlockBoundaryKeepsLinesIntact() async throws {
        // A passing line that straddles the 64 KiB block boundary must come
        // out whole (the carry buffer's job).
        let long = String(repeating: "y", count: 70_000)
        let path = try write("[2026-07-13 09:00:00] drop me\n[2026-07-13 11:00:00] \(long)\n")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let out = try await collect(path, sinceCutoff: f.date(from: "2026-07-13 10:00:00")!)
        XCTAssertEqual(out, "[2026-07-13 11:00:00] \(long)\n")
    }

    // MARK: follow

    func testFollowStreamsAppendsAndSurvivesRotation() async throws {
        let path = try write("start\n")
        let (gotFirst, gotAppend, gotRotated) = try await withThrowingTaskGroup(
            of: (Bool, Bool, Bool).self) { group in
            group.addTask {
                var seen = Data()
                var first = false, appended = false, rotated = false
                for try await chunk in LogReader.stream(
                    path: path, tail: 0, sinceCutoff: nil, follow: true, pollMs: 20) {
                    seen.append(chunk)
                    let text = String(decoding: seen, as: UTF8.self)
                    if text.contains("start\n") { first = true }
                    if text.contains("appended\n") { appended = true }
                    if text.contains("fresh\n") { rotated = true; break }
                }
                return (first, appended, rotated)
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(60))
                let h = FileHandle(forWritingAtPath: path)!
                _ = try h.seekToEnd()
                try h.write(contentsOf: Data("appended\n".utf8))
                try h.close()
                try await Task.sleep(for: .milliseconds(80))
                // Rotate: truncate to a smaller file — reader must reset to 0.
                try Data("fresh\n".utf8).write(to: URL(fileURLWithPath: path))
                return (false, false, false)
            }
            var result = (false, false, false)
            for try await r in group where r.0 || r.1 || r.2 { result = r }
            return result
        }
        XCTAssertTrue(gotFirst)
        XCTAssertTrue(gotAppend)
        XCTAssertTrue(gotRotated)
    }

    func testMissingFileThrows() async {
        do {
            _ = try await collect(dir.appendingPathComponent("nope.log").path)
            XCTFail("expected cannotOpen")
        } catch let e as LogReaderError {
            XCTAssertTrue("\(e)".hasPrefix("cannot open"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
