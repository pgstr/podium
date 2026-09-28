import Foundation
import Yams

// MARK: - Top-level

/// Minimal docker-compose file model — only the fields podium can act on.
/// Decoded with Yams; every polymorphic field uses a bespoke `init(from:)`.
struct ComposeFile: Decodable {
    var name: String?
    var services: [String: ComposeService]
    /// Top-level `volumes:` block — the discriminator between bind mounts and named volumes.
    /// A non-path source in a service's `volumes:` list is a named volume only if it appears here.
    var volumes: [String: ComposeVolumeDecl?]?

    enum CodingKeys: String, CodingKey { case name, services, volumes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name     = try c.decodeIfPresent(String.self, forKey: .name)
        services = try c.decodeIfPresent([String: ComposeService].self, forKey: .services) ?? [:]
        volumes  = try c.decodeIfPresent([String: ComposeVolumeDecl?].self, forKey: .volumes)
    }
}

/// Top-level volume declaration — discriminates named volumes from bind mounts.
/// An empty or null value (`pgdata: {}` / `pgdata:`) means a local managed volume (the common case).
struct ComposeVolumeDecl: Decodable {
    var driver: String?
    var external: Bool?
    // driver_opts intentionally ignored — no driver metadata needed for local volumes
}

// MARK: - Service

struct ComposeService: Decodable {
    var image: String?
    var entrypoint: ComposeCommand?
    var command: ComposeCommand?
    var workingDir: String?
    var environment: ComposeEnv?
    var envFile: ComposeEnvFile?
    var volumes: [ComposeVolume]
    var dependsOn: ComposeDependsOn?
    var healthcheck: ComposeHealthcheck?
    var restart: String?
    var memLimit: String?
    var cpus: Double?
    var deploy: ComposeDeploy?
    var xPodium: PodiumExtension?
    /// Parsed host/container mappings from `ports:`. The runtime binds each
    /// host side and relays TCP connections to the container side.
    var ports: [ComposePort]

    // Dropped fields — collected for warnings, not decoded into model state.
    var droppedFields: [String] = []

    enum CodingKeys: String, CodingKey {
        case image, entrypoint, command
        case workingDir  = "working_dir"
        case environment
        case envFile     = "env_file"
        case volumes
        case dependsOn   = "depends_on"
        case healthcheck
        case restart
        case memLimit    = "mem_limit"
        case cpus
        case deploy
        case xPodium     = "x-podium"
        case ports
        // truly dropped (no podium equivalent)
        case build, networks, profiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image       = try c.decodeIfPresent(String.self,            forKey: .image)
        entrypoint  = try c.decodeIfPresent(ComposeCommand.self,    forKey: .entrypoint)
        command     = try c.decodeIfPresent(ComposeCommand.self,    forKey: .command)
        workingDir  = try c.decodeIfPresent(String.self,            forKey: .workingDir)
        environment = try c.decodeIfPresent(ComposeEnv.self,        forKey: .environment)
        envFile     = try c.decodeIfPresent(ComposeEnvFile.self,    forKey: .envFile)
        volumes     = try c.decodeIfPresent([ComposeVolume].self,   forKey: .volumes) ?? []
        dependsOn   = try c.decodeIfPresent(ComposeDependsOn.self,  forKey: .dependsOn)
        healthcheck = try c.decodeIfPresent(ComposeHealthcheck.self, forKey: .healthcheck)
        restart     = try c.decodeIfPresent(String.self,            forKey: .restart)
        memLimit    = try c.decodeIfPresent(String.self,            forKey: .memLimit)
        cpus        = try c.decodeIfPresent(Double.self,            forKey: .cpus)
        deploy      = try c.decodeIfPresent(ComposeDeploy.self,     forKey: .deploy)
        xPodium     = try c.decodeIfPresent(PodiumExtension.self,   forKey: .xPodium)
        ports       = try c.decodeIfPresent([ComposePort].self,     forKey: .ports) ?? []

        // Record truly-dropped fields for warnings.
        for key in [CodingKeys.build, .networks, .profiles] {
            if c.contains(key) { droppedFields.append(key.rawValue) }
        }
    }
}

// MARK: - Polymorphic command (string | array)

enum ComposeCommand: Decodable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let s = try? decoder.singleValueContainer()
        if let str = try? s?.decode(String.self) { self = .string(str); return }
        if let arr = try? s?.decode([String].self) { self = .array(arr); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "command must be a string or array"))
    }

    /// Convert to podium argv.
    var argv: [String] {
        switch self {
        case .string(let s): return s.isEmpty ? [] : ["/bin/sh", "-c", s]
        case .array(let a):  return a
        }
    }
}

// MARK: - Polymorphic environment (dict | list)

enum ComposeEnv: Decodable {
    case dict([String: String])
    case list([String])

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        if let d = try? s.decode([String: String].self) { self = .dict(d); return }
        if let l = try? s.decode([String].self)         { self = .list(l); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "environment must be a mapping or sequence"))
    }

    /// Merge into an existing env dict; entries already present are NOT overwritten.
    func merge(into base: inout [String: String]) {
        switch self {
        case .dict(let d):
            for (k, v) in d where base[k] == nil { base[k] = v }
        case .list(let l):
            for entry in l {
                let parts = entry.split(separator: "=", maxSplits: 1)
                if parts.count == 2, base[String(parts[0])] == nil {
                    base[String(parts[0])] = String(parts[1])
                } else if parts.count == 1, let val = ProcessInfo.processInfo.environment[String(parts[0])],
                          base[String(parts[0])] == nil {
                    // bare KEY — inherit from host env if present
                    base[String(parts[0])] = val
                }
            }
        }
    }

    /// Return as a plain dict (used when applying environment: which wins over env_file).
    var asDict: [String: String] {
        switch self {
        case .dict(let d): return d
        case .list(let l):
            var out: [String: String] = [:]
            for entry in l {
                let parts = entry.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
                else if parts.count == 1,
                        let val = ProcessInfo.processInfo.environment[String(parts[0])] {
                    out[String(parts[0])] = val
                }
            }
            return out
        }
    }
}

// MARK: - env_file (string | array)

enum ComposeEnvFile: Decodable {
    case single(String)
    case multiple([String])

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        if let str = try? s.decode(String.self)  { self = .single(str);    return }
        if let arr = try? s.decode([String].self) { self = .multiple(arr); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "env_file must be a string or array"))
    }

    var paths: [String] { switch self { case .single(let s): return [s]; case .multiple(let a): return a } }
}

// MARK: - Ports (short "[[host:]:]containerPort[/proto]" | long-form object)
// Captures both host and container ports from compose `ports:` entries.

enum ComposePort: Decodable {
    case short(String)
    case long(target: Int, published: String?, hostIP: String?)

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        // Short form: "80", "80/tcp", "8080:80", "127.0.0.1:8080:80"
        if let str = try? s.decode(String.self) { self = .short(str); return }
        // Long form: { target: 80, published: "8080", host_ip: "127.0.0.1", protocol: "tcp" }
        struct Long: Decodable {
            let target: Int?; let published: String?; let hostIP: String?
            enum CodingKeys: String, CodingKey { case target, published, hostIP = "host_ip" }
        }
        if let lf = try? s.decode(Long.self), let t = lf.target {
            self = .long(target: t, published: lf.published, hostIP: lf.hostIP); return
        }
        self = .short("") // unparseable entry — toPortForward returns nil
    }

    /// Resolve to a `PortForward`, or nil if unparseable.
    ///
    /// An explicit bind IP ("127.0.0.1:8080:80" / long-form `host_ip`) is
    /// honored. Entries without one get `defaultBind` (loopback unless the
    /// service opts in via `x-podium: {publish: true}`).
    func toPortForward(defaultBind: String) -> PortForward? {
        switch self {
        case .short(let s):
            guard !s.isEmpty else { return nil }
            // Strip protocol suffix ("80/tcp" → "80").
            let withoutProto = s.split(separator: "/").first.map(String.init) ?? s
            let segs = withoutProto.split(separator: ":").map(String.init)
            guard let containerPort = segs.last.flatMap(Int.init) else { return nil }
            // Second-to-last segment (if present) is the host port.
            let hostPort: Int
            if segs.count >= 2, let hp = Int(segs[segs.count - 2]) {
                hostPort = hp
            } else {
                hostPort = containerPort  // no explicit host port → same as container
            }
            // First segment of a 3-part form is the bind IP.
            let bind = segs.count >= 3 ? segs[0] : defaultBind
            return PortForward(host: hostPort, container: containerPort, bindAddress: bind)
        case .long(let target, let published, let hostIP):
            let hostPort = published.flatMap(Int.init) ?? target
            return PortForward(host: hostPort, container: target,
                               bindAddress: hostIP ?? defaultBind)
        }
    }
}

// MARK: - Volumes (short "src:dst[:ro]" | long-form object)

enum ComposeVolume: Decodable {
    case short(String)
    /// source is nil for anonymous volumes (long-form without a source field).
    case long(source: String?, target: String, readOnly: Bool)

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        if let str = try? s.decode(String.self) { self = .short(str); return }
        // long-form
        struct Long: Decodable {
            let source: String?; let target: String; let readOnly: Bool?
            enum CodingKeys: String, CodingKey { case source, target, readOnly = "read_only" }
        }
        if let lf = try? s.decode(Long.self) {
            self = .long(source: lf.source, target: lf.target, readOnly: lf.readOnly ?? false)
            return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "volume must be a shorthand string or long-form object with a target"))
    }

    /// Resolve to a `VolumeMount`, using `volumeDecls` to discriminate named volumes from bind mounts.
    ///
    /// - path source (`/`, `./`, `../`, `~`) → bind mount
    /// - declared named source → managed volume (`name` field)
    /// - anonymous (no source) → managed volume with derived name `<svc>-<hash(dst)>`
    /// - undeclared / external / non-local driver → typed error
    func toMount(serviceId: String, volumeDecls: [String: ComposeVolumeDecl?]?) throws -> VolumeMount {
        switch self {
        case .short(let s):
            let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 1 {
                // anonymous volume: `- /var/lib/mysql` — no source, destination only
                return VolumeMount(name: "\(serviceId)-\(shortHash(parts[0]))",
                                   destination: parts[0])
            }
            let src = parts[0]
            let dst = parts[1]
            // options: ro, cached, delegated, z, Z — strip non-ro hints
            var ro = false
            if parts.count == 3 {
                let opts = parts[2].split(separator: ",").map(String.init)
                ro = opts.contains("ro")
                // cached/delegated/z/Z are macOS-irrelevant hints; silently ignored
            }
            return try resolveVolumeSource(src, destination: dst, readOnly: ro,
                                           serviceId: serviceId, volumeDecls: volumeDecls)

        case .long(let src, let dst, let ro):
            guard let src else {
                // anonymous long-form: no source field
                return VolumeMount(name: "\(serviceId)-\(shortHash(dst))", destination: dst,
                                   readOnly: ro)
            }
            return try resolveVolumeSource(src, destination: dst, readOnly: ro,
                                           serviceId: serviceId, volumeDecls: volumeDecls)
        }
    }
}

/// Discriminate a volume source string between a bind-mount path and a named volume.
private func resolveVolumeSource(
    _ src: String,
    destination dst: String,
    readOnly ro: Bool,
    serviceId: String,
    volumeDecls: [String: ComposeVolumeDecl?]?
) throws -> VolumeMount {
    // Host path: starts with /, ./, ../, or ~
    if src.hasPrefix("/") || src.hasPrefix(".") || src.hasPrefix("~") {
        return VolumeMount(source: src, destination: dst, readOnly: ro)
    }
    // Named volume — must appear in top-level `volumes:`
    guard let decls = volumeDecls, decls.keys.contains(src) else {
        throw ComposeError.undeclaredVolume(service: serviceId, name: src)
    }
    let decl = decls[src] ?? nil   // decls[src] is ComposeVolumeDecl?? — unwrap outer Optional
    if decl?.external == true {
        throw ComposeError.externalVolumeUnsupported(name: src)
    }
    let driver = decl?.driver ?? "local"
    guard driver == "local" else {
        throw ComposeError.volumeDriverUnsupported(name: src, driver: driver)
    }
    return VolumeMount(name: src, destination: dst, readOnly: ro)
}

/// FNV-1a 32-bit hash — stable, dependency-free, for deterministic anonymous volume names.
private func shortHash(_ s: String) -> String {
    var h: UInt32 = 2166136261
    for byte in s.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
    return String(format: "%08x", h)
}

// MARK: - depends_on (list | dict with condition)

enum ComposeDependsOn: Decodable {
    case list([String])
    case dict([String: DepCondition])

    struct DepCondition: Decodable {
        let condition: String?
        enum CodingKeys: String, CodingKey { case condition }
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        if let list = try? s.decode([String].self)              { self = .list(list); return }
        if let dict = try? s.decode([String: DepCondition].self) { self = .dict(dict); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "depends_on must be a list or mapping"))
    }

    var ids: [String] {
        switch self {
        case .list(let l): return l
        case .dict(let d): return Array(d.keys).sorted()
        }
    }
}

// MARK: - healthcheck

struct ComposeHealthcheck: Decodable {
    var test: ComposeHealthTest?
    // interval/retries/start_period map onto podium's per-service probe
    // tuning (livenessIntervalSeconds / livenessFailThreshold /
    // healthTimeoutSeconds). `timeout` is unsupported (probe execs have no
    // per-run deadline) and surfaces as a translation warning.
    var interval: String?
    var retries: Int?
    var startPeriod: String?
    var timeout: String?

    init(from decoder: Decoder) throws {
        enum CK: String, CodingKey {
            case test, interval, retries, timeout
            case startPeriod = "start_period"
        }
        let c = try decoder.container(keyedBy: CK.self)
        test = try c.decodeIfPresent(ComposeHealthTest.self, forKey: .test)
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        retries = try c.decodeIfPresent(Int.self, forKey: .retries)
        startPeriod = try c.decodeIfPresent(String.self, forKey: .startPeriod)
        timeout = try c.decodeIfPresent(String.self, forKey: .timeout)
    }
}

enum ComposeHealthTest: Decodable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        if let str = try? s.decode(String.self)  { self = .string(str); return }
        if let arr = try? s.decode([String].self) { self = .array(arr); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "healthcheck.test must be a string or array"))
    }

    /// Convert to podium healthCheck command, or nil if NONE.
    var toCommand: [String]? {
        switch self {
        case .string(let s):
            return ["/bin/sh", "-c", s]
        case .array(let a):
            guard let first = a.first else { return nil }
            switch first {
            case "NONE":      return nil
            case "CMD":       return Array(a.dropFirst())
            case "CMD-SHELL":
                let shell = a.dropFirst().joined(separator: " ")
                return ["/bin/sh", "-c", shell]
            default:          return a   // bare array without type prefix
            }
        }
    }
}

// MARK: - deploy (resources.limits)

struct ComposeDeploy: Decodable {
    var resources: Resources?
    struct Resources: Decodable {
        var limits: Limits?
        struct Limits: Decodable {
            var memory: String?
            var cpus: String?   // compose uses a quoted decimal string here
        }
    }
}

// MARK: - x-podium extension

struct PodiumExtension: Decodable {
    var rootfsGB: UInt64?
    var memoryMB: UInt64?
    var cpus: Int?
    var secrets: [String: String]?
    /// `publish: true` binds this service's ports (those without an explicit
    /// bind IP) on all interfaces instead of the loopback-only default.
    var publish: Bool?
}

// MARK: - Variable interpolation

/// True for characters that may appear in a compose variable name.
private func isVarNameChar(_ c: Character) -> Bool {
    (c.isLetter && c.isASCII) || (c.isNumber && c.isASCII) || c == "_"
}
/// True for characters that may *start* a compose variable name.
private func isVarNameStart(_ c: Character) -> Bool {
    (c.isLetter && c.isASCII) || c == "_"
}

/// Interpolate compose variable references before YAML decoding, matching docker
/// compose semantics: `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?err}`,
/// `${VAR?err}`, bare `$VAR`, and `$$` as a literal `$`. Unset variables without a
/// default substitute the empty string and produce a warning (like docker compose).
/// Nested substitutions in defaults are not supported.
func interpolateComposeVars(
    _ text: String, values: [String: String]
) throws -> (text: String, warnings: [String]) {
    var out = ""
    out.reserveCapacity(text.count)
    var warnings: [String] = []
    var i = text.startIndex

    func resolveBraced(_ body: String) throws -> String {
        var idx = body.startIndex
        if idx < body.endIndex, isVarNameStart(body[idx]) {
            idx = body.index(after: idx)
            while idx < body.endIndex, isVarNameChar(body[idx]) { idx = body.index(after: idx) }
        }
        let name = String(body[..<idx])
        guard !name.isEmpty else { throw ComposeError.badInterpolation("${\(body)}") }
        let rest = String(body[idx...])
        let value = values[name]
        if rest.isEmpty {
            if let v = value { return v }
            warnings.append("variable '\(name)' is not set — substituting empty string")
            return ""
        }
        if rest.hasPrefix(":-") {
            if let v = value, !v.isEmpty { return v }
            return String(rest.dropFirst(2))
        }
        if rest.hasPrefix(":?") {
            if let v = value, !v.isEmpty { return v }
            throw ComposeError.requiredVariable(name: name, message: String(rest.dropFirst(2)))
        }
        if rest.hasPrefix("-") {
            return value ?? String(rest.dropFirst(1))
        }
        if rest.hasPrefix("?") {
            if let v = value { return v }
            throw ComposeError.requiredVariable(name: name, message: String(rest.dropFirst(1)))
        }
        throw ComposeError.badInterpolation("${\(body)}")
    }

    while i < text.endIndex {
        let ch = text[i]
        guard ch == "$" else { out.append(ch); i = text.index(after: i); continue }
        let next = text.index(after: i)
        guard next < text.endIndex else { out.append(ch); break }

        if text[next] == "$" {                              // $$ → literal $
            out.append("$")
            i = text.index(after: next)
            continue
        }
        if text[next] == "{" {                              // ${...}
            let bodyStart = text.index(after: next)
            guard let close = text[bodyStart...].firstIndex(of: "}") else {
                throw ComposeError.badInterpolation(String(text[i...].prefix(24)))
            }
            out.append(try resolveBraced(String(text[bodyStart..<close])))
            i = text.index(after: close)
            continue
        }
        if isVarNameStart(text[next]) {                     // bare $VAR
            var j = text.index(after: next)
            while j < text.endIndex, isVarNameChar(text[j]) { j = text.index(after: j) }
            let name = String(text[next..<j])
            if let v = values[name] {
                out.append(v)
            } else {
                warnings.append("variable '\(name)' is not set — substituting empty string")
            }
            i = j
            continue
        }
        out.append(ch)                                      // lone $ (e.g. "$1")
        i = next
    }
    return (out, warnings)
}

/// Parse a `.env`-style file (KEY=VALUE lines, # comments) into a dictionary.
func parseDotEnv(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        var val = String(parts[1])
        // Strip one layer of matching quotes, as docker compose does.
        if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
                           (val.hasPrefix("'") && val.hasSuffix("'")) {
            val = String(val.dropFirst().dropLast())
        }
        out[String(parts[0])] = val
    }
    return out
}

// MARK: - Errors

enum ComposeError: Error, CustomStringConvertible {
    case missingImage(service: String)
    /// Non-path volume source that has no entry in the top-level `volumes:` block.
    case undeclaredVolume(service: String, name: String)
    /// Volume is declared with `external: true` — it lives outside this project.
    case externalVolumeUnsupported(name: String)
    /// Volume uses a non-local driver (NFS, cloud, etc.) that podium cannot honour.
    case volumeDriverUnsupported(name: String, driver: String)
    /// `${...}` reference that could not be parsed.
    case badInterpolation(String)
    /// `${VAR:?msg}` / `${VAR?msg}` with the variable unset.
    case requiredVariable(name: String, message: String)

    var description: String {
        switch self {
        case .missingImage(let s):
            return "service '\(s)': no image and no build — nothing to run"
        case .undeclaredVolume(let s, let n):
            return "service '\(s)': named volume '\(n)' must be declared in the top-level 'volumes:' block"
        case .externalVolumeUnsupported(let n):
            return "volume '\(n)': external volumes are not supported — the volume must live inside this project"
        case .volumeDriverUnsupported(let n, let d):
            return "volume '\(n)': driver '\(d)' is not supported — only 'local' volumes are managed by podium"
        case .badInterpolation(let s):
            return "cannot parse variable reference '\(s)' (nested defaults are not supported)"
        case .requiredVariable(let n, let m):
            return "required variable '\(n)' is not set\(m.isEmpty ? "" : ": \(m)")"
        }
    }
}

// MARK: - Memory parsing

/// Parse compose memory strings like "512m", "1g", "1024" (bytes) → MB.
func parseMB(_ raw: String) -> UInt64? {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasSuffix("g"),  let v = Double(s.dropLast()) { return UInt64(v * 1024) }
    if s.hasSuffix("gb"), let v = Double(s.dropLast(2)) { return UInt64(v * 1024) }
    if s.hasSuffix("m"),  let v = Double(s.dropLast()) { return UInt64(v) }
    if s.hasSuffix("mb"), let v = Double(s.dropLast(2)) { return UInt64(v) }
    if s.hasSuffix("k"),  let v = Double(s.dropLast()) { return UInt64(v / 1024) }
    if let bytes = UInt64(s) { return bytes / (1024 * 1024) }
    return nil
}

// MARK: - Translation

extension ComposeFile {
    /// Translate this compose file into a native `Stack`.
    /// `projectName` is used as the stack name when `compose.name` is absent.
    /// Returns the stack and a list of human-readable warnings for dropped fields.
    func toStack(projectName: String) throws -> (stack: Stack, warnings: [String]) {
        var warnings: [String] = []

        // Stable ordering: sort service names so apply is reproducible.
        let orderedNames = services.keys.sorted()

        var specs: [ServiceSpec] = []
        for name in orderedNames {
            let svc = services[name]!

            // — dropped fields —
            for field in svc.droppedFields {
                warnings.append("service '\(name)': '\(field)' is not supported by podium and will be ignored")
            }

            // — image —
            guard let image = svc.image else {
                if svc.droppedFields.contains("build") {
                    throw ComposeError.missingImage(service: name)
                }
                throw ComposeError.missingImage(service: name)
            }

            // — env: env_file first (lower precedence), then environment overrides —
            var env: [String: String] = [:]
            if let ef = svc.envFile {
                for path in ef.paths {
                    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                        warnings.append("service '\(name)': env_file '\(path)' not found — skipping")
                        continue
                    }
                    for line in content.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                        let parts = trimmed.split(separator: "=", maxSplits: 1)
                        if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
                    }
                }
            }
            if let e = svc.environment {
                // environment: always wins over env_file
                for (k, v) in e.asDict { env[k] = v }
            }

            // — entrypoint / command —
            // The non-nil empty args marker activates Podium's split process
            // model, so Compose `command` replaces image CMD while retaining
            // image ENTRYPOINT. An entrypoint override drops image CMD unless
            // Compose also supplies command, matching the Compose spec.
            let entrypoint = svc.entrypoint?.argv
            let command = svc.command?.argv
            let processArgs: [String]? = (svc.entrypoint != nil || svc.command != nil) ? [] : nil

            // — volumes —
            var volumes: [VolumeMount] = []
            for v in svc.volumes {
                let mount = try v.toMount(serviceId: name, volumeDecls: self.volumes)
                volumes.append(mount)
            }

            // — depends_on —
            let dependsOn = svc.dependsOn?.ids ?? []

            // — healthCheck + probe tuning —
            let healthCheck = svc.healthcheck?.test?.toCommand
            var livenessIntervalSeconds: Int? = nil
            var livenessFailThreshold: Int? = nil
            var healthTimeoutSeconds = 60
            if let hc = svc.healthcheck {
                if let raw = hc.interval {
                    if let secs = parseDuration(raw), secs >= 1 {
                        livenessIntervalSeconds = Int(secs)
                    } else {
                        warnings.append("service '\(name)': unparseable healthcheck.interval '\(raw)' — using default")
                    }
                }
                livenessFailThreshold = hc.retries
                if let raw = hc.startPeriod {
                    if let secs = parseDuration(raw), secs >= 1 {
                        healthTimeoutSeconds = Int(secs)
                    } else {
                        warnings.append("service '\(name)': unparseable healthcheck.start_period '\(raw)' — using default")
                    }
                }
                if hc.timeout != nil {
                    warnings.append("service '\(name)': healthcheck.timeout is not supported "
                        + "(probe execs have no per-run deadline) — ignored")
                }
            }

            // — restart policy —
            let restartPolicy: RestartPolicy
            switch svc.restart ?? "no" {
            case "always", "unless-stopped": restartPolicy = .always
            case "on-failure":               restartPolicy = .onFailure
            default:                         restartPolicy = .no
            }

            // — resource limits: deploy.resources.limits < mem_limit / cpus (direct wins) —
            var memoryMB: UInt64 = 512
            if let lim = svc.deploy?.resources?.limits?.memory, let mb = parseMB(lim) { memoryMB = mb }
            if let ml  = svc.memLimit, let mb = parseMB(ml) { memoryMB = mb }

            var cpus: Int = 1
            if let dc = svc.deploy?.resources?.limits?.cpus, let v = Double(dc) { cpus = max(1, Int(v.rounded(.up))) }
            if let sc = svc.cpus { cpus = max(1, Int(sc.rounded(.up))) }

            // — x-podium overlay (highest precedence) —
            let xp = svc.xPodium
            let finalMemMB  = xp?.memoryMB  ?? memoryMB
            let finalCPUs   = xp?.cpus      ?? cpus
            let finalRootGB = xp?.rootfsGB  ?? 1
            let secrets     = xp?.secrets   ?? [:]

            // — ports: capture host and container side; relay binds the host port.
            // No explicit bind IP → loopback, unless the service opts in via
            // x-podium publish: true.
            let defaultBind = (xp?.publish == true) ? "0.0.0.0" : PortForward.defaultBindAddress
            let portForwards = svc.ports.compactMap { $0.toPortForward(defaultBind: defaultBind) }
            if !portForwards.isEmpty {
                let addrs = portForwards
                    .map { "\($0.bindDisplay):\($0.hostPort) → <ip>:\($0.containerPort)" }
                    .joined(separator: ", ")
                warnings.append("service '\(name)': ports: → \(addrs)")
                if xp?.publish != true,
                   portForwards.contains(where: { $0.bindAddress == PortForward.defaultBindAddress }) {
                    warnings.append("service '\(name)': host ports bind loopback by default — "
                        + "set `x-podium: {publish: true}` or an explicit bind IP to expose on all interfaces")
                }
            }

            specs.append(ServiceSpec(
                id: name, image: image,
                command: command, entrypoint: entrypoint, args: processArgs,
                workingDirectory: svc.workingDir,
                env: env, secrets: secrets,
                cpus: finalCPUs, memoryMB: finalMemMB, rootfsGB: finalRootGB,
                volumes: volumes, dependsOn: dependsOn,
                healthCheck: healthCheck, restartPolicy: restartPolicy,
                portForwards: portForwards,
                healthTimeoutSeconds: healthTimeoutSeconds,
                livenessIntervalSeconds: livenessIntervalSeconds,
                livenessFailThreshold: livenessFailThreshold
            ))
        }

        return (Stack(name: projectName, services: specs), warnings)
    }
}
