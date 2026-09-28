import Foundation
import XCTest
@testable import PodiumDaemon

final class OperationalDiagnosticsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-ops-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    func testDoctorReportRendersRemediationAndFailureStatus() {
        let report = DoctorReport(checks: [
            .init(name: "kernel", status: .pass, detail: "/x/vmlinux"),
            .init(name: "vminit", status: .fail, detail: "missing",
                  remediation: "run `podium prepare-runtime`"),
        ])
        XCTAssertTrue(report.hasFailures)
        XCTAssertEqual(report.rendered(), [
            "[PASS] kernel — /x/vmlinux",
            "[FAIL] vminit — missing",
            "       fix: run `podium prepare-runtime`",
        ].joined(separator: "\n"))
    }

    func testDoctorExecutablePathUsesActualExecutableForBareCommandName() {
        let executable = URL(fileURLWithPath: "/usr/local/bin/podium")
        XCTAssertEqual(
            DoctorExecutablePath.resolve(argv0: "podium", bundleExecutableURL: executable),
            "/usr/local/bin/podium")
    }

    func testStalePruneRemovesOnlyEphemeralFiles() throws {
        for name in ["podium.sock", "daemon.pid", "lock", "secrets.env", "daemon.log"] {
            try Data(name.utf8).write(to: tmp.appendingPathComponent(name))
        }
        for directory in ["state", "logs", "volumes"] {
            let url = tmp.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: url.appendingPathComponent("keep"))
        }

        XCTAssertEqual(try StaleStackFiles.prune(directory: tmp),
                       ["podium.sock", "daemon.pid"])
        for name in ["lock", "secrets.env", "daemon.log",
                     "state/keep", "logs/keep", "volumes/keep"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent(name).path), "must preserve \(name)")
        }
    }
}
