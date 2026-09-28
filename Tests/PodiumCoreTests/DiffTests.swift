// DiffTests.swift — classifyStackDiff, the pure logic behind `podium diff`
// and `reload`.
import XCTest
@testable import PodiumCore

final class DiffTests: XCTestCase {

    func svc(_ id: String, image: String = "img", memoryMB: UInt64 = 512) -> ServiceSpec {
        ServiceSpec(id: id, image: image, command: nil, workingDirectory: nil,
                    env: [:], secrets: [:], cpus: 1, memoryMB: memoryMB, rootfsGB: 1,
                    volumes: [], dependsOn: [],
                    healthCheck: nil, restartPolicy: .always)
    }

    func testClassifyAllBuckets() {
        let old = Stack(name: "s", services: [svc("a"), svc("b"), svc("c")])
        let new = Stack(name: "s", services: [svc("b", memoryMB: 1024), svc("c"), svc("d")])
        let diff = classifyStackDiff(old: old, new: new)
        XCTAssertEqual(diff.stopped, ["a"])      // in old, gone from new
        XCTAssertEqual(diff.restarted, ["b"])    // spec changed
        XCTAssertEqual(diff.unchanged, ["c"])    // identical
        XCTAssertEqual(diff.started, ["d"])      // brand new
    }

    func testClassifyIdentityIsAllUnchanged() {
        let stack = Stack(name: "s", services: [svc("a"), svc("b")])
        let diff = classifyStackDiff(old: stack, new: stack)
        XCTAssertEqual(diff, StackDiff(started: [], stopped: [], restarted: [],
                                       unchanged: ["a", "b"]))
    }

    func testClassifyPreservesDeclarationOrder() {
        let old = Stack(name: "s", services: [svc("z"), svc("m"), svc("a")])
        let new = Stack(name: "s", services: [svc("q"), svc("a", image: "img2"), svc("m")])
        let diff = classifyStackDiff(old: old, new: new)
        XCTAssertEqual(diff.stopped, ["z"])                 // old order
        XCTAssertEqual(diff.started, ["q"])                 // new order
        XCTAssertEqual(diff.restarted, ["a"])
        XCTAssertEqual(diff.unchanged, ["m"])
    }

    func testAnyFieldChangeTriggersRestart() {
        // Equality is the restart trigger — spot-check a few fields beyond image.
        let base = svc("a")
        var envChanged = base; envChanged.env = ["K": "v"]
        var volChanged = base; volChanged.volumes = [VolumeMount(name: "data", destination: "/d")]
        var portChanged = base; portChanged.portForwards = [PortForward(8080)]
        for changed in [envChanged, volChanged, portChanged] {
            let diff = classifyStackDiff(old: Stack(name: "s", services: [base]),
                                         new: Stack(name: "s", services: [changed]))
            XCTAssertEqual(diff.restarted, ["a"])
            XCTAssertTrue(diff.unchanged.isEmpty)
        }
    }

    /// StackDiff's JSON shape is stable.
    func testStackDiffEncodesLegacyShape() throws {
        let diff = StackDiff(started: ["a"], stopped: [], restarted: ["b"], unchanged: [])
        let data = try JSONEncoder().encode(diff)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["started", "stopped", "restarted", "unchanged"])
        XCTAssertEqual(obj["started"] as? [String], ["a"])
    }
}
