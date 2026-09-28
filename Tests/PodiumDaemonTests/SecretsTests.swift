import Foundation
import XCTest
@testable import PodiumDaemon

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SecretsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-secrets-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func write(_ text: String, mode: Int = 0o600) throws -> URL {
        let url = tmp.appendingPathComponent("secrets.env")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func testPerStackPathIsAbsoluteAndSanitized() {
        let path = StackPaths.secretsPath(for: "demo / unsafe")
        XCTAssertTrue((path as NSString).isAbsolutePath)
        XCTAssertTrue(path.hasSuffix("/.podium/demo-unsafe/secrets.env"), path)
    }

    func testLoadsOwnedMode0600File() throws {
        let url = try write("# comment\nTOKEN = canary-value\nEMPTY=\n")
        let provider = FileSecretsProvider(path: url.path, expectedOwnerID: getuid())

        XCTAssertEqual(try provider.value(for: "TOKEN"), "canary-value")
        XCTAssertEqual(try provider.value(for: "EMPTY"), "")
    }

    func testRejectsBroaderPermissionsWithoutLeakingValues() throws {
        let canary = "CANARY-permissions-secret"
        let url = try write("TOKEN=\(canary)\n", mode: 0o640)
        let provider = FileSecretsProvider(path: url.path, expectedOwnerID: getuid())

        XCTAssertThrowsError(try provider.value(for: "TOKEN")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("expected 0600"), message)
            XCTAssertFalse(message.contains(canary), message)
        }
    }

    func testRejectsWrongOwnerExpectationWithoutReadingValues() throws {
        let canary = "CANARY-owner-secret"
        let url = try write("TOKEN=\(canary)\n")
        let provider = FileSecretsProvider(
            path: url.path, expectedOwnerID: getuid() &+ 1)

        XCTAssertThrowsError(try provider.value(for: "TOKEN")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("owned by uid"), message)
            XCTAssertFalse(message.contains(canary), message)
        }
    }

    func testRejectsSymlink() throws {
        let target = try write("TOKEN=CANARY-symlink-secret\n")
        let link = tmp.appendingPathComponent("linked.env")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: target.path)
        let provider = FileSecretsProvider(path: link.path, expectedOwnerID: getuid())

        XCTAssertThrowsError(try provider.value(for: "TOKEN")) { error in
            XCTAssertTrue(String(describing: error).contains("cannot read secrets file"))
        }
    }

    func testMissingKeyAndMissingFileNeverListValues() throws {
        let canary = "CANARY-unlisted-secret"
        let url = try write("OTHER=\(canary)\n")
        let provider = FileSecretsProvider(path: url.path, expectedOwnerID: getuid())

        XCTAssertThrowsError(try provider.value(for: "TOKEN")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("secret 'TOKEN' not found"), message)
            XCTAssertFalse(message.contains(canary), message)
        }

        let absent = FileSecretsProvider(
            path: tmp.appendingPathComponent("absent.env").path,
            expectedOwnerID: getuid())
        XCTAssertThrowsError(try absent.value(for: "TOKEN")) { error in
            XCTAssertTrue(String(describing: error).contains("cannot read secrets file"))
        }
    }

    func testRedactorHandlesBinaryDataAndOverlappingValues() {
        let redactor = SecretRedactor(values: ["token", "token-long", ""])
        let input = Data([0xff]) + Data(" token-long token ".utf8) + Data([0xfe])
        let output = redactor.redact(input)

        XCTAssertNil(output.range(of: Data("token".utf8)))
        XCTAssertNil(output.range(of: Data("token-long".utf8)))
        XCTAssertNotNil(output.range(of: Data("[REDACTED]".utf8)))
        XCTAssertEqual(output.first, 0xff)
        XCTAssertEqual(output.last, 0xfe)
    }
}
