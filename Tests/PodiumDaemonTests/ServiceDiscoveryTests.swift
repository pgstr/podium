import XCTest
@testable import PodiumDaemon

final class ServiceDiscoveryTests: XCTestCase {
    let running = [
        RuntimeContainerConfig.HostEntry(ip: "10.0.0.3", hostname: "web"),
        RuntimeContainerConfig.HostEntry(ip: "10.0.0.2", hostname: "db"),
    ]

    func testLegacyDiscoveryKeepsSortedPeerHosts() throws {
        let inputs = try ServiceDiscovery.inputs(
            serviceID: "web", managedDNSEnabled: false,
            runningEntries: running, dnsIP: nil)

        XCTAssertEqual(inputs.hostEntries, [
            .init(ip: "10.0.0.2", hostname: "db"),
        ])
        XCTAssertNil(inputs.dns)
    }

    func testManagedDNSClientUsesResolverWithoutStaticPeerHosts() throws {
        let inputs = try ServiceDiscovery.inputs(
            serviceID: "web", managedDNSEnabled: true,
            runningEntries: running, dnsIP: "10.0.0.9")

        XCTAssertEqual(inputs.hostEntries, [])
        XCTAssertEqual(inputs.dns, .init(
            nameservers: ["10.0.0.9"],
            searchDomains: ["podium.local"],
            options: ["ndots:1"]))
    }

    func testManagedDNSServerUsesRuntimeDefaults() throws {
        let inputs = try ServiceDiscovery.inputs(
            serviceID: "podium-dns", managedDNSEnabled: true,
            runningEntries: running, dnsIP: nil)

        XCTAssertEqual(inputs.hostEntries, [])
        XCTAssertNil(inputs.dns)
    }

    func testManagedDNSClientFailsClearlyWhenResolverIsUnavailable() {
        XCTAssertThrowsError(try ServiceDiscovery.inputs(
            serviceID: "web", managedDNSEnabled: true,
            runningEntries: running, dnsIP: nil)) { error in
                XCTAssertTrue(error is ManagedDNSUnavailableError)
            }
    }
}
