import PodiumCore

struct ServiceDiscoveryInputs: Equatable {
    let hostEntries: [RuntimeContainerConfig.HostEntry]
    let dns: RuntimeContainerConfig.DNSConfiguration?
}

struct ManagedDNSUnavailableError: Error, CustomStringConvertible {
    var description: String {
        "managed DNS is not running and ready; start '\(ManagedDNS.serviceID)' first"
    }
}

/// Chooses one discovery mechanism for a container. Stacks without managed
/// DNS get peer `/etc/hosts` injection; managed-DNS stacks use only their
/// CoreDNS sidecar so a peer IP can change without restarting every client.
enum ServiceDiscovery {
    static func inputs(serviceID: String,
                       managedDNSEnabled: Bool,
                       runningEntries: [RuntimeContainerConfig.HostEntry],
                       dnsIP: String?) throws -> ServiceDiscoveryInputs {
        if !managedDNSEnabled {
            return ServiceDiscoveryInputs(
                hostEntries: runningEntries
                    .filter { $0.hostname != serviceID }
                    .sorted { $0.hostname < $1.hostname },
                dns: nil)
        }
        if serviceID == ManagedDNS.serviceID {
            return ServiceDiscoveryInputs(hostEntries: [], dns: nil)
        }
        guard let dnsIP else { throw ManagedDNSUnavailableError() }
        return ServiceDiscoveryInputs(
            hostEntries: [],
            dns: .init(nameservers: [dnsIP],
                       searchDomains: [ManagedDNS.domain],
                       options: ["ndots:1"]))
    }
}
