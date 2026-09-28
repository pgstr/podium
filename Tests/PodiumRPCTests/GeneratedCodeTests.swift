// GeneratedCodeTests.swift — codegen sanity for Sources/PodiumRPC/Generated.
//
// The generated proto code is checked in (`make proto`); this smoke
// test pins the basics so a stale or hand-edited regeneration fails fast:
// a message round-trip through binary serialization, and the service name
// the daemon registers under. Behavior tests for the PodiumControl service
// itself live in PodiumControlServiceTests (in-process transport).

import XCTest
import PodiumRPC

final class GeneratedCodeTests: XCTestCase {

    func testInfoResponseBinaryRoundTrip() throws {
        var info = PbInfoResponse()
        info.daemonVersion = "1.2.3"
        info.protocolVersion = 7
        info.stackName = "demo"
        info.pid = 4242

        let bytes = try info.serializedData()
        let back = try PbInfoResponse(serializedBytes: bytes)
        XCTAssertEqual(back, info)
        XCTAssertEqual(back.daemonVersion, "1.2.3")
        XCTAssertEqual(back.protocolVersion, 7)
        XCTAssertEqual(back.stackName, "demo")
        XCTAssertEqual(back.pid, 4242)
    }

    func testServiceDescriptorName() {
        // The CLI dials this fully-qualified name; a drift here is a
        // wire-protocol break, not a refactor.
        XCTAssertEqual(PbPodiumControl.descriptor.fullyQualifiedService, "podium.v1.PodiumControl")
    }
}
