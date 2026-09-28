import Foundation

/// Durable, atomically refreshed inputs for the generated CoreDNS sidecar.
public enum DNSHostsStore {
    public static let corefile = """
    .:53 {
        errors
        hosts /config/hosts {
            ttl 1
            reload 1s
            fallthrough
        }
        forward . /etc/resolv.conf
    }
    """

    public static func prepare(directory: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try writeIfChanged(corefile + "\n", to: path(directory, "Corefile"))
        let hosts = path(directory, "hosts")
        if !fm.fileExists(atPath: hosts) {
            try Data().write(to: URL(fileURLWithPath: hosts), options: .atomic)
        }
    }

    public static func update(directory: String,
                              entries: [RuntimeContainerConfig.HostEntry]) throws {
        try prepare(directory: directory)
        try writeIfChanged(render(entries), to: path(directory, "hosts"))
    }

    public static func render(_ entries: [RuntimeContainerConfig.HostEntry]) -> String {
        let lines = entries.sorted { $0.hostname < $1.hostname }.map {
            "\($0.ip) \($0.hostname) \($0.hostname).podium.local"
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func path(_ directory: String, _ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    private static func writeIfChanged(_ text: String, to path: String) throws {
        let data = Data(text.utf8)
        if (try? Data(contentsOf: URL(fileURLWithPath: path))) == data { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
