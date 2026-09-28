import Foundation
import XCTest
@testable import PodiumDaemon

final class TUITests: XCTestCase {
    func testKeyBindingsAreExplicit() {
        XCTAssertEqual(TUIKey.action(for: UInt8(ascii: "j")), .selectNext)
        XCTAssertEqual(TUIKey.action(for: UInt8(ascii: "k")), .selectPrevious)
        XCTAssertEqual(TUIKey.action(for: UInt8(ascii: "a")), .start)
        XCTAssertEqual(TUIKey.action(for: UInt8(ascii: "s")), .stop)
        XCTAssertEqual(TUIKey.action(for: UInt8(ascii: "r")), .restart)
        XCTAssertEqual(TUIKey.action(for: UInt8(ascii: "l")), .reload)
        XCTAssertEqual(TUIKey.action(for: 0x03), .quit)
        XCTAssertNil(TUIKey.action(for: UInt8(ascii: "x")))
    }

    func testServiceRefreshPreservesSelectionByID() {
        var state = TUIState(stack: "demo", services: [service("a"), service("b")])
        state.moveSelection(by: 1)
        state.replaceServices([service("b"), service("c")])
        XCTAssertEqual(state.selectedService?.id, "b")
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testLogChunksJoinLinesSanitizeControlsAndStayBounded() {
        var state = TUIState(stack: "demo", services: [service("web")], maxLogLines: 2)
        state.appendLogChunk(Data("one\ntw".utf8))
        state.appendLogChunk(Data("o\n\u{1b}[31mthree\n".utf8))
        XCTAssertEqual(state.logLines, ["two", " [31mthree"])
    }

    func testRendererMarksSelectionAndIncludesLatestLogs() {
        var state = TUIState(stack: "demo", services: [
            service("web", ip: "10.0.0.2"), service("worker", state: "stopped")
        ])
        state.moveSelection(by: 1)
        state.appendLogChunk(Data("first\nsecond\n".utf8))
        state.setMessage("restart worker: ok")
        let rendered = TUIRender.frame(state, width: 90, height: 16)
        XCTAssertTrue(rendered.contains("› worker"))
        XCTAssertTrue(rendered.contains("LOG  worker"))
        XCTAssertTrue(rendered.contains("second"))
        XCTAssertTrue(rendered.contains("STATUS  restart worker: ok"))
        XCTAssertEqual(rendered.components(separatedBy: "\r\n").count, 16)
    }

    private func service(
        _ id: String, state: String = "running", ip: String? = nil
    ) -> ServiceStatus {
        ServiceStatus(
            id: id, state: state, ready: state == "running", starts: 1,
            startedAt: state == "running" ? Date() : nil, ip: ip)
    }
}
