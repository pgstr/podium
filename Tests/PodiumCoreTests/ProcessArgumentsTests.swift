import XCTest
@testable import PodiumCore

final class ProcessArgumentsTests: XCTestCase {
    let imageEntrypoint = ["/image-entrypoint"]
    let imageCommand = ["serve", "--port", "80"]

    func testNoOverridesUsesImageEntrypointAndCommand() {
        XCTAssertEqual(resolve(), ["/image-entrypoint", "serve", "--port", "80"])
    }

    func testLegacyCommandOnlyRemainsFullArgvOverride() {
        XCTAssertEqual(resolve(command: ["/bin/sh", "-c", "echo old"]),
                       ["/bin/sh", "-c", "echo old"])
    }

    func testSplitCommandKeepsImageEntrypoint() {
        XCTAssertEqual(resolve(command: ["version"], args: []),
                       ["/image-entrypoint", "version"])
    }

    func testEntrypointOverrideDropsImageCommand() {
        XCTAssertEqual(resolve(entrypoint: ["/custom"]), ["/custom"])
    }

    func testExplicitEmptyEntrypointClearsImageEntrypoint() {
        XCTAssertEqual(resolve(entrypoint: [], command: ["/bin/true"], args: []),
                       ["/bin/true"])
    }

    func testArgsAppendToSelectedImageDefaults() {
        XCTAssertEqual(resolve(args: ["--verbose"]),
                       ["/image-entrypoint", "serve", "--port", "80", "--verbose"])
    }

    private func resolve(entrypoint: [String]? = nil,
                         command: [String]? = nil,
                         args: [String]? = nil) -> [String] {
        ProcessArguments.resolve(
            imageEntrypoint: imageEntrypoint, imageCommand: imageCommand,
            entrypoint: entrypoint, command: command, args: args)
    }
}
