import Foundation
import XCTest
@testable import PodiumDaemon

final class DNSHostsStoreTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-dns-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testPrepareWritesCorefileAndEmptyHosts() throws {
        try DNSHostsStore.prepare(directory: directory.path)
        let corefile = try String(contentsOf: directory.appendingPathComponent("Corefile"),
                                  encoding: .utf8)
        XCTAssertEqual(corefile, DNSHostsStore.corefile + "\n")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("hosts")), Data())
    }

    func testUpdateWritesSortedShortAndSearchDomainNames() throws {
        try DNSHostsStore.update(directory: directory.path, entries: [
            .init(ip: "10.0.0.3", hostname: "web"),
            .init(ip: "10.0.0.2", hostname: "db"),
        ])
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("hosts"), encoding: .utf8),
            "10.0.0.2 db db.podium.local\n10.0.0.3 web web.podium.local\n")
    }

    func testPrepareDoesNotTruncateExistingHosts() throws {
        try DNSHostsStore.update(directory: directory.path,
                                 entries: [.init(ip: "10.0.0.2", hostname: "db")])
        try DNSHostsStore.prepare(directory: directory.path)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("hosts"), encoding: .utf8),
            "10.0.0.2 db db.podium.local\n")
    }
}
