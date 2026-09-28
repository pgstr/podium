import Foundation
import XCTest
@testable import PodiumDaemon

final class StructuredLoggingTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-structured-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    func testStructuredLineIsMachineParseableJSONLWithLevel() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let line = try StructuredLogging.line(
            message: "[state] WARN: disk nearly full", stack: "demo", timestamp: date)

        XCTAssertEqual(line.last, 0x0a)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["level"] as? String, "warning")
        XCTAssertEqual(object["stack"] as? String, "demo")
        XCTAssertEqual(object["message"] as? String, "[state] WARN: disk nearly full")
        XCTAssertNotNil(object["timestamp"] as? String)
    }

    func testRotatingSinkStrictlyCapsCurrentAndArchives() throws {
        let path = tmp.appendingPathComponent("daemon.log").path
        let sink = try RotatingLogSink(path: path, maxBytes: 64, archives: 3)
        let input = Data((0..<200).map { UInt8($0) })
        try sink.append(input)
        try sink.close()

        let paths = ["\(path).3", "\(path).2", "\(path).1", path]
        let chunks = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 64 })
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, input)
    }

    func testExistingOversizedFileRotatesOnOpen() throws {
        let path = tmp.appendingPathComponent("service.log").path
        try Data(repeating: 0x61, count: 65).write(to: URL(fileURLWithPath: path))

        let sink = try RotatingLogSink(path: path, maxBytes: 64, archives: 1)
        try sink.append(Data("new".utf8))
        try sink.close()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("new".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: "\(path).1")).count, 65)
    }
}
