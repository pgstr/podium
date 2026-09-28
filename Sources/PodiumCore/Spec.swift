import Foundation
import Yams

private extension String {
    /// Returns `self` if non-empty, else `nil`.
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A host-directory bind mount or podium-managed volume exposed to a service.
/// Exactly one of `source` or `name` must be set (validated by `Stack.validate()`).
///
/// - `source`: host path for a bind mount (virtiofs share).
/// - `name`: managed volume key; podium resolves it to `~/.podium/<stack>/volumes/<name>/`,
///   creating the directory on demand. Never auto-deleted. Shared across services that
///   reference the same name within a stack.
public struct VolumeMount: Codable, Sendable, Equatable {
    /// Host path for a bind mount. Mutually exclusive with `name`.
    public let source: String?
    /// Managed-volume name. Podium picks and owns the host path.
    /// Mutually exclusive with `source`.
    public let name: String?
    public let destination: String   // path inside the container
    public var readOnly: Bool

    /// Bind-mount init.
    public init(source: String, destination: String, readOnly: Bool = false) {
        self.source = source; self.name = nil
        self.destination = destination; self.readOnly = readOnly
    }

    /// Managed-volume init.
    public init(name: String, destination: String, readOnly: Bool = false) {
        self.source = nil; self.name = name
        self.destination = destination; self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey { case source, name, destination, readOnly }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source      = try c.decodeIfPresent(String.self, forKey: .source)
        name        = try c.decodeIfPresent(String.self, forKey: .name)
        destination = try c.decode(String.self, forKey: .destination)
        readOnly    = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }
}

/// A one-shot setup step that runs to completion before the main container starts.
/// All steps share the main service's image, environment, and volume mounts.
/// Non-zero exit → the service is marked failed immediately; no backoff retry.
public struct InitStep: Codable, Sendable, Equatable {
    public let command: [String]
}

/// A TCP port mapping from a host-side port to a container-side port.
///
/// In native JSON, the `"ports"` key accepts integers (same port on both sides) or objects:
/// ```json
/// "ports": [8080, {"hostPort": 4430, "containerPort": 443}]
/// ```
/// Integer `8080` is shorthand for `{"hostPort": 8080, "containerPort": 8080}`.
///
public struct PortForward: Codable, Sendable, Equatable {
    /// Host-side address the listener binds. Defaults to loopback —
    /// secure by default; use "0.0.0.0" to publish on all interfaces.
    public static let defaultBindAddress = "127.0.0.1"

    /// Port bound on the host at `bindAddress`.
    public let hostPort: Int
    /// Port the container listens on.
    public let containerPort: Int
    /// Host-side bind address ("127.0.0.1" default, "0.0.0.0" to publish).
    public let bindAddress: String

    public init(host: Int, container: Int, bindAddress: String = PortForward.defaultBindAddress) {
        self.hostPort = host; self.containerPort = container; self.bindAddress = bindAddress
    }

    /// Convenience: same port on both sides, loopback bind.
    public init(_ port: Int) {
        self.hostPort = port; self.containerPort = port
        self.bindAddress = PortForward.defaultBindAddress
    }

    enum CodingKeys: String, CodingKey { case hostPort, containerPort, bindAddress }

    /// Decodes an integer shorthand or an explicit `{hostPort, containerPort[, bindAddress]}` object.
    public init(from decoder: Decoder) throws {
        // Integer shorthand: 80 → {hostPort:80, containerPort:80, loopback}
        if let single = try? decoder.singleValueContainer().decode(Int.self) {
            self.hostPort = single; self.containerPort = single
            self.bindAddress = PortForward.defaultBindAddress
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostPort = try c.decode(Int.self, forKey: .hostPort)
        self.containerPort = try c.decode(Int.self, forKey: .containerPort)
        self.bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress)
            ?? PortForward.defaultBindAddress
    }

    /// Display form of the bind address: "*" when published on all interfaces.
    public var bindDisplay: String { bindAddress == "0.0.0.0" ? "*" : bindAddress }
}

/// What to do when a service's container exits.
public enum RestartPolicy: String, Codable, Sendable {
    case always           // restart on any exit (default)
    case onFailure = "on-failure"  // restart only on non-zero exit
    case no               // never restart
}

/// One service in a podium stack. Native-clean schema (not compose).
/// Custom `init(from:)` so a stack file may omit fields and get sane defaults
/// (Swift's synthesized Codable does NOT apply property defaults for missing keys).
public struct ServiceSpec: Codable, Sendable, Equatable {
    public let id: String
    public let image: String
    /// Full argv override on its own. When `entrypoint` or `args` is present,
    /// it overrides only the image CMD (split process model).
    public var command: [String]?
    /// OCI ENTRYPOINT override. nil keeps the image entrypoint; [] clears it.
    public var entrypoint: [String]?
    /// Extra argv appended after the selected command. Presence (including [])
    /// activates split process semantics.
    public var args: [String]?
    /// If omitted, the image's WORKDIR is kept.
    public var workingDirectory: String?
    public var env: [String: String]
    /// env-var name -> key in `~/.podium/<stack>/secrets.env`; resolved at start,
    /// never committed.
    public var secrets: [String: String]
    public var cpus: Int
    public var memoryMB: UInt64
    public var rootfsGB: UInt64
    /// host-directory bind mounts (virtiofs shares).
    public var volumes: [VolumeMount]
    /// ids this service must wait for before starting (health-gated — see healthCheck).
    public var dependsOn: [String]
    /// optional readiness probe: a command run via `exec` inside the container; exit 0 = healthy.
    /// If nil, the service is "ready" as soon as it's running.
    public var healthCheck: [String]?
    /// Seconds to poll `healthCheck` before giving up on readiness. The service
    /// keeps running but stays not-ready; an `unready` event is emitted. Default 60.
    public var healthTimeoutSeconds: Int
    /// Ongoing liveness probe. If set, replaces healthCheck for continuous probing after startup.
    /// healthCheck still gates the startup readiness check. If only healthCheck is set, it serves both roles.
    public var livenessCheck: [String]?
    /// Seconds between liveness probes. nil → daemon default (10).
    /// Mapped from compose `healthcheck.interval`.
    public var livenessIntervalSeconds: Int?
    /// Consecutive liveness failures before the container is killed and
    /// restarted. nil → daemon default (3). Mapped from compose
    /// `healthcheck.retries`.
    public var livenessFailThreshold: Int?
    public var restartPolicy: RestartPolicy
    /// One-shot init containers that run to completion before the main container starts.
    public var initContainers: [InitStep]
    /// Standard 5-field cron expression ("min hour dom month dow"). When set, the service runs as a
    /// one-shot on the schedule and is not started by the normal reconciler. restartPolicy is ignored.
    public var schedule: String?
    /// Port mappings for this service. Each entry optionally binds a host port → container port.
    /// In native JSON: `"ports": [8080, {"hostPort": 4430, "containerPort": 443}]`.
    /// Populated automatically from Compose `ports:`.
    public var portForwards: [PortForward]

    /// Plain init used by the compose adapter and tests.
    public init(id: String, image: String, command: [String]?,
         entrypoint: [String]? = nil, args: [String]? = nil,
         workingDirectory: String?,
         env: [String: String], secrets: [String: String],
         cpus: Int, memoryMB: UInt64, rootfsGB: UInt64,
         volumes: [VolumeMount], dependsOn: [String],
         healthCheck: [String]?, restartPolicy: RestartPolicy,
         initContainers: [InitStep] = [], schedule: String? = nil,
         livenessCheck: [String]? = nil, portForwards: [PortForward] = [],
         healthTimeoutSeconds: Int = 60,
         livenessIntervalSeconds: Int? = nil, livenessFailThreshold: Int? = nil) {
        self.id = id; self.image = image; self.command = command
        self.entrypoint = entrypoint; self.args = args
        self.workingDirectory = workingDirectory; self.env = env; self.secrets = secrets
        self.cpus = cpus; self.memoryMB = memoryMB; self.rootfsGB = rootfsGB
        self.volumes = volumes; self.dependsOn = dependsOn
        self.healthCheck = healthCheck; self.livenessCheck = livenessCheck
        self.restartPolicy = restartPolicy
        self.initContainers = initContainers; self.schedule = schedule
        self.portForwards = portForwards
        self.healthTimeoutSeconds = healthTimeoutSeconds
        self.livenessIntervalSeconds = livenessIntervalSeconds
        self.livenessFailThreshold = livenessFailThreshold
    }

    enum CodingKeys: String, CodingKey {
        case id, image, entrypoint, command, args, workingDirectory, env, secrets, cpus, memoryMB, rootfsGB
        case volumes, dependsOn, healthCheck, livenessCheck, restartPolicy, schedule
        case healthTimeoutSeconds, livenessIntervalSeconds, livenessFailThreshold
        case portForwards = "ports"
        case initContainers = "init"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        image = try c.decode(String.self, forKey: .image)
        entrypoint = try c.decodeIfPresent([String].self, forKey: .entrypoint)
        command = try c.decodeIfPresent([String].self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 1
        memoryMB = try c.decodeIfPresent(UInt64.self, forKey: .memoryMB) ?? 512
        rootfsGB = try c.decodeIfPresent(UInt64.self, forKey: .rootfsGB) ?? 1
        volumes = try c.decodeIfPresent([VolumeMount].self, forKey: .volumes) ?? []
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        healthCheck = try c.decodeIfPresent([String].self, forKey: .healthCheck)
        healthTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .healthTimeoutSeconds) ?? 60
        livenessCheck = try c.decodeIfPresent([String].self, forKey: .livenessCheck)
        livenessIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .livenessIntervalSeconds)
        livenessFailThreshold = try c.decodeIfPresent(Int.self, forKey: .livenessFailThreshold)
        restartPolicy = try c.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .always
        initContainers = try c.decodeIfPresent([InitStep].self, forKey: .initContainers) ?? []
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule)
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
    }
}

/// One hostname routed by the generated managed-ingress Caddy service.
public struct IngressRoute: Codable, Sendable, Equatable {
    public let host: String
    public let service: String
    public let port: Int

    public init(host: String, service: String, port: Int) {
        self.host = host
        self.service = service
        self.port = port
    }
}

/// Top-level managed ingress declaration. It is normalized into an ordinary
/// generated service during decode, so the reconciler needs no ingress-specific path.
public struct IngressSpec: Codable, Sendable, Equatable {
    public static let serviceID = "podium-ingress"
    public static let image = "docker.io/library/caddy:2-alpine"

    public let hostPort: Int
    public let bindAddress: String
    public let routes: [IngressRoute]

    public init(hostPort: Int = 8080,
                bindAddress: String = PortForward.defaultBindAddress,
                routes: [IngressRoute]) {
        self.hostPort = hostPort
        self.bindAddress = bindAddress
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey { case hostPort, bindAddress, routes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostPort = try c.decodeIfPresent(Int.self, forKey: .hostPort) ?? 8080
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress)
            ?? PortForward.defaultBindAddress
        routes = try c.decode([IngressRoute].self, forKey: .routes)
    }

    func generatedService(declaredServices: [ServiceSpec]) throws -> ServiceSpec {
        guard !routes.isEmpty else { throw IngressConfigurationError.noRoutes }
        guard (1...65535).contains(hostPort) else {
            throw IngressConfigurationError.invalidHostPort(hostPort)
        }
        guard bindAddress == "127.0.0.1" || bindAddress == "0.0.0.0" else {
            throw IngressConfigurationError.invalidBindAddress(bindAddress)
        }
        guard !declaredServices.contains(where: { $0.id == Self.serviceID }) else {
            throw IngressConfigurationError.reservedServiceID(Self.serviceID)
        }

        var services: [String: ServiceSpec] = [:]
        for service in declaredServices {
            guard services[service.id] == nil else {
                throw IngressConfigurationError.duplicateServiceID(service.id)
            }
            services[service.id] = service
        }
        var seenHosts = Set<String>()
        var dependencies: [String] = []
        for route in routes {
            guard Self.isValidHostname(route.host) else {
                throw IngressConfigurationError.invalidHost(route.host)
            }
            guard seenHosts.insert(route.host).inserted else {
                throw IngressConfigurationError.duplicateHost(route.host)
            }
            guard let backend = services[route.service] else {
                throw IngressConfigurationError.unknownService(route.service)
            }
            guard backend.schedule == nil else {
                throw IngressConfigurationError.scheduledService(route.service)
            }
            guard (1...65535).contains(route.port) else {
                throw IngressConfigurationError.invalidTargetPort(service: route.service,
                                                                  port: route.port)
            }
            if !dependencies.contains(route.service) { dependencies.append(route.service) }
        }

        let probe = ["wget", "-q", "-O-", "http://127.0.0.1:2019/config/"]
        return ServiceSpec(
            id: Self.serviceID,
            image: Self.image,
            command: [
                "/bin/sh", "-c",
                "printf '%s' \"$PODIUM_CADDYFILE\" > /tmp/Caddyfile && exec caddy run --config /tmp/Caddyfile --adapter caddyfile",
            ],
            workingDirectory: nil,
            env: ["PODIUM_CADDYFILE": Self.caddyfile(routes: routes)],
            secrets: [:],
            cpus: 1,
            memoryMB: 256,
            rootfsGB: 1,
            volumes: [],
            dependsOn: dependencies,
            healthCheck: probe,
            restartPolicy: .always,
            livenessCheck: probe,
            portForwards: [PortForward(host: hostPort, container: 80,
                                       bindAddress: bindAddress)]
        )
    }

    private static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    private static func caddyfile(routes: [IngressRoute]) -> String {
        let sites = routes.map { route in
            """
            http://\(route.host) {
                reverse_proxy \(route.service):\(route.port)
            }
            """
        }
        return (["""
        {
            admin localhost:2019
            auto_https off
        }
        """] + sites).joined(separator: "\n\n")
    }
}

enum IngressConfigurationError: Error, CustomStringConvertible {
    case noRoutes
    case invalidHostPort(Int)
    case invalidBindAddress(String)
    case reservedServiceID(String)
    case duplicateServiceID(String)
    case invalidHost(String)
    case duplicateHost(String)
    case unknownService(String)
    case scheduledService(String)
    case invalidTargetPort(service: String, port: Int)

    var description: String {
        switch self {
        case .noRoutes:
            return "ingress must declare at least one route"
        case .invalidHostPort(let port):
            return "ingress hostPort \(port) must be between 1 and 65535"
        case .invalidBindAddress(let address):
            return "ingress bindAddress '\(address)' must be 127.0.0.1 or 0.0.0.0"
        case .reservedServiceID(let id):
            return "service id '\(id)' is reserved when managed ingress is enabled"
        case .duplicateServiceID(let id):
            return "duplicate service id '\(id)'"
        case .invalidHost(let host):
            return "invalid ingress hostname '\(host)'"
        case .duplicateHost(let host):
            return "duplicate ingress hostname '\(host)'"
        case .unknownService(let service):
            return "ingress routes to unknown service '\(service)'"
        case .scheduledService(let service):
            return "ingress cannot route to scheduled service '\(service)'"
        case .invalidTargetPort(let service, let port):
            return "ingress target port \(port) for service '\(service)' must be between 1 and 65535"
        }
    }
}

/// Constants and normalized service definition for optional stack-local DNS.
public enum ManagedDNS {
    public static let serviceID = "podium-dns"
    public static let volumeName = "podium-dns-config"
    public static let domain = "podium.local"
    public static let image = "docker.io/coredns/coredns:1.12.4"

    static func generatedService() -> ServiceSpec {
        let probe = ["/coredns", "-version"]
        return ServiceSpec(
            id: serviceID,
            image: image,
            command: ["/coredns", "-conf", "/config/Corefile"],
            workingDirectory: nil,
            env: [:],
            secrets: [:],
            cpus: 1,
            memoryMB: 128,
            rootfsGB: 1,
            volumes: [VolumeMount(name: volumeName, destination: "/config")],
            dependsOn: [],
            healthCheck: probe,
            restartPolicy: .always,
            livenessCheck: probe
        )
    }
}

enum ManagedDNSConfigurationError: Error, CustomStringConvertible {
    case reservedServiceID(String)
    case duplicateServiceID(String)

    var description: String {
        switch self {
        case .reservedServiceID(let id):
            return "service id '\(id)' is reserved when managed DNS is enabled"
        case .duplicateServiceID(let id):
            return "duplicate service id '\(id)'"
        }
    }
}

/// A declared stack: the desired set of services for this host.
public struct Stack: Codable, Sendable {
    public let name: String
    public let services: [ServiceSpec]

    public init(name: String, services: [ServiceSpec]) {
        self.name = name; self.services = services
    }

    enum CodingKeys: String, CodingKey { case name, services, ingress, dns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let declared = try c.decode([ServiceSpec].self, forKey: .services)
        let dnsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dns) ?? false
        var normalized = declared
        if dnsEnabled {
            var seen = Set<String>()
            for service in declared {
                guard seen.insert(service.id).inserted else {
                    throw ManagedDNSConfigurationError.duplicateServiceID(service.id)
                }
                guard service.id != ManagedDNS.serviceID else {
                    throw ManagedDNSConfigurationError.reservedServiceID(service.id)
                }
            }
            normalized = [ManagedDNS.generatedService()] + declared.map { service in
                var client = service
                if !client.dependsOn.contains(ManagedDNS.serviceID) {
                    client.dependsOn.append(ManagedDNS.serviceID)
                }
                return client
            }
        }
        if let ingress = try c.decodeIfPresent(IngressSpec.self, forKey: .ingress) {
            normalized.append(try ingress.generatedService(declaredServices: declared))
        }
        services = normalized
    }

    /// Applied specs are normalized: the generated service is persisted directly and
    /// the source-only `ingress` declaration is omitted, preventing double expansion.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(services, forKey: .services)
    }

    /// Load a stack from a JSON (`stack.json`) or YAML (`docker-compose.yml`) file.
    /// Compose files are adapted in-memory; the source file is never rewritten.
    public static func load(_ path: String) throws -> Stack {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "yml" || ext == "yaml" {
            return try Stack.loadCompose(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Stack.self, from: data)
    }

    public static func loadCompose(_ path: String) throws -> Stack {
        let raw = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)

        // Variable interpolation before YAML decoding, docker-compose style.
        // Values come from a `.env` next to the compose file, overridden by the
        // process environment (same precedence as docker compose).
        var values: [String: String] = [:]
        let envPath = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".env").path
        if let envText = try? String(contentsOfFile: envPath, encoding: .utf8) {
            values = parseDotEnv(envText)
        }
        for (k, v) in ProcessInfo.processInfo.environment { values[k] = v }
        let (interpolated, interpWarnings) = try interpolateComposeVars(raw, values: values)
        for w in interpWarnings {
            FileHandle.standardError.write(Data("[compose] warning: \(w)\n".utf8))
        }

        let compose = try YAMLDecoder().decode(ComposeFile.self, from: interpolated)
        // Project name: compose `name:` field (validated as-is) → parent directory
        // name, normalized into the valid charset (directories aren't user "names").
        let projectName = compose.name
            ?? Stack.normalizeName(
                URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                    .nonEmpty ?? "compose")
        let (stack, warnings) = try compose.toStack(projectName: projectName)
        for w in warnings {
            FileHandle.standardError.write(Data("[compose] warning: \(w)\n".utf8))
        }
        return stack
    }

    /// Charset rule for stack names and service IDs. IDs feed container IDs,
    /// filenames, /etc/hosts hostnames, and the control protocol — so: lowercase
    /// alphanumerics with interior `-`/`_`, 1–32 chars, no leading/trailing separator.
    /// (Underscore is allowed for compose compatibility; note it is nonstandard in
    /// hostnames, so prefer `-` for services addressed by name.)
    public static func isValidName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9]([a-z0-9_-]{0,30}[a-z0-9])?$", options: .regularExpression) != nil
    }

    /// Normalize a *derived* name (e.g. a compose project name taken from a directory)
    /// into the valid charset. Explicit user-provided names are validated, not normalized.
    public static func normalizeName(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        let collapsed = String(mapped).components(separatedBy: "-").filter { !$0.isEmpty }
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(32))
        return trimmed.isEmpty ? "stack" : trimmed
    }

    /// Validate the stack before bringing it up.
    /// Catches invalid names, unknown `dependsOn` references and dependency cycles (DFS).
    public func validate() throws {
        guard Stack.isValidName(name) else {
            throw StackValidationError.invalidStackName(name: name)
        }
        for svc in services where !Stack.isValidName(svc.id) {
            throw StackValidationError.invalidServiceId(id: svc.id)
        }
        var seenIDs = Set<String>()
        for svc in services where !seenIDs.insert(svc.id).inserted {
            throw StackValidationError.duplicateServiceId(id: svc.id)
        }
        let ids = Set(services.map { $0.id })
        for svc in services {
            for dep in svc.dependsOn {
                guard ids.contains(dep) else {
                    throw StackValidationError.unknownDependency(service: svc.id, dep: dep)
                }
            }
        }
        // DFS cycle detection: white=0 (unvisited), gray=1 (in stack), black=2 (done).
        var color: [String: Int] = [:]
        func visit(_ id: String) throws {
            if color[id] == 2 { return }
            if color[id] == 1 { throw StackValidationError.cycle(service: id) }
            color[id] = 1
            for dep in (services.first { $0.id == id }?.dependsOn ?? []) { try visit(dep) }
            color[id] = 2
        }
        for svc in services { try visit(svc.id) }

        // Validate cron expressions are parseable.
        for svc in services {
            if let expr = svc.schedule, CronSchedule(expr) == nil {
                throw StackValidationError.invalidSchedule(service: svc.id, expr: expr)
            }
        }

        // Each VolumeMount must have exactly one of source/name (not both, not neither).
        for svc in services {
            for v in svc.volumes {
                let hasSource = v.source != nil
                let hasName   = v.name   != nil
                guard hasSource != hasName else {
                    throw StackValidationError.volumeSourceXorName(service: svc.id, destination: v.destination)
                }
            }
        }
    }
}

enum StackValidationError: Error, CustomStringConvertible {
    case unknownDependency(service: String, dep: String)
    case cycle(service: String)
    case volumeSourceXorName(service: String, destination: String)
    case invalidSchedule(service: String, expr: String)
    case invalidStackName(name: String)
    case invalidServiceId(id: String)
    case duplicateServiceId(id: String)
    public var description: String {
        switch self {
        case .unknownDependency(let s, let d):
            return "service '\(s)' depends on unknown id '\(d)'"
        case .cycle(let s):
            return "dependency cycle detected involving '\(s)'"
        case .volumeSourceXorName(let s, let d):
            return "service '\(s)': volume '\(d)' must have exactly one of 'source' or 'name' (not both, not neither)"
        case .invalidSchedule(let s, let e):
            return "service '\(s)': invalid cron expression '\(e)'"
        case .invalidStackName(let n):
            return "invalid stack name '\(n)' — use 1–32 lowercase alphanumerics with interior '-'/'_'"
        case .invalidServiceId(let i):
            return "invalid service id '\(i)' — use 1–32 lowercase alphanumerics with interior '-'/'_'"
        case .duplicateServiceId(let i):
            return "duplicate service id '\(i)'"
        }
    }
}
