// ComposeTests.swift — unit tests for compose translation.
// Covers the field-mapping table, volumes (short/long/anonymous/named/external/
// driver), ports (all short forms + bind IP), env precedence,
// healthcheck forms, restart mapping, the x-podium overlay, and the
// interpolation pass (${VAR}, defaults, required, $$, bare $VAR).
import XCTest
import Yams
@testable import PodiumCore

final class ComposeTests: XCTestCase {

    // MARK: helpers

    /// Decode YAML → ComposeFile → Stack; fails the test on error.
    func translate(_ yaml: String, project: String = "proj",
                   file: StaticString = #filePath, line: UInt = #line)
    throws -> (stack: Stack, warnings: [String]) {
        let compose = try YAMLDecoder().decode(ComposeFile.self, from: yaml)
        return try compose.toStack(projectName: project)
    }

    func service(_ yaml: String, _ id: String = "web",
                 file: StaticString = #filePath, line: UInt = #line) throws -> ServiceSpec {
        let (stack, _) = try translate(yaml)
        guard let svc = stack.services.first(where: { $0.id == id }) else {
            XCTFail("service '\(id)' missing from translated stack", file: file, line: line)
            throw ComposeError.missingImage(service: id)
        }
        return svc
    }

    // MARK: field mapping

    func testBasicFieldMapping() throws {
        let svc = try service("""
        services:
          web:
            image: nginx:1.27
            working_dir: /srv
            environment:
              A: "1"
        """)
        XCTAssertEqual(svc.image, "nginx:1.27")
        XCTAssertEqual(svc.workingDirectory, "/srv")
        XCTAssertEqual(svc.env, ["A": "1"])
        XCTAssertNil(svc.command)
        // defaults when compose says nothing
        XCTAssertEqual(svc.cpus, 1)
        XCTAssertEqual(svc.memoryMB, 512)
        XCTAssertEqual(svc.rootfsGB, 1)
    }

    func testServicesSortedForReproducibleApply() throws {
        let (stack, _) = try translate("""
        services:
          zeta: {image: a}
          alpha: {image: b}
          mid: {image: c}
        """)
        XCTAssertEqual(stack.services.map { $0.id }, ["alpha", "mid", "zeta"])
    }

    func testMissingImageThrows() {
        XCTAssertThrowsError(try translate("services:\n  web: {working_dir: /srv}\n")) { err in
            guard case ComposeError.missingImage(let s) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(s, "web")
        }
    }

    func testDroppedFieldsWarn() throws {
        let (_, warnings) = try translate("""
        services:
          web:
            image: img
            build: .
            networks: [front]
            profiles: [debug]
        """)
        for field in ["build", "networks", "profiles"] {
            XCTAssertTrue(warnings.contains { $0.contains("'\(field)'") },
                          "no warning for dropped '\(field)': \(warnings)")
        }
    }

    // MARK: command (string | array)

    func testCommandStringBecomesShC() throws {
        let svc = try service("services:\n  web: {image: img, command: echo hi}\n")
        XCTAssertEqual(svc.command, ["/bin/sh", "-c", "echo hi"])
        XCTAssertEqual(svc.args, [], "marker activates image-entrypoint-preserving split mode")
    }

    func testCommandArrayIsArgv() throws {
        let svc = try service("services:\n  web: {image: img, command: [nginx, -g, daemon off;]}\n")
        XCTAssertEqual(svc.command, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(svc.args, [])
    }

    func testEntrypointAndCommandTranslateSeparately() throws {
        let svc = try service("""
        services:
          web:
            image: img
            entrypoint: [/init, /wrapper]
            command: [gateway, run]
        """)
        XCTAssertEqual(svc.entrypoint, ["/init", "/wrapper"])
        XCTAssertEqual(svc.command, ["gateway", "run"])
        XCTAssertEqual(svc.args, [])
    }

    func testEmptyEntrypointAndCommandRemainExplicitOverrides() throws {
        let svc = try service("""
        services:
          web:
            image: img
            entrypoint: []
            command: []
        """)
        XCTAssertEqual(svc.entrypoint, [])
        XCTAssertEqual(svc.command, [])
        XCTAssertEqual(svc.args, [])
    }

    // MARK: environment (dict | list) + env_file precedence

    func testEnvironmentListForm() throws {
        let svc = try service("""
        services:
          web:
            image: img
            environment:
              - A=1
              - B=x=y
        """)
        XCTAssertEqual(svc.env, ["A": "1", "B": "x=y"])   // split on first '=' only
    }

    func testEnvironmentBareKeyInheritsProcessEnv() throws {
        setenv("PODIUM_TEST_BARE_KEY", "from-host", 1)
        defer { unsetenv("PODIUM_TEST_BARE_KEY") }
        let svc = try service("""
        services:
          web:
            image: img
            environment:
              - PODIUM_TEST_BARE_KEY
        """)
        XCTAssertEqual(svc.env["PODIUM_TEST_BARE_KEY"], "from-host")
    }

    func testEnvFileLowerPrecedenceThanEnvironment() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-envfile-\(UUID().uuidString).env")
        try "FROM_FILE=file\nSHARED=file\n# comment\nnot a pair\n"
            .write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = try service("""
        services:
          web:
            image: img
            env_file: \(tmp.path)
            environment:
              SHARED: env
        """)
        XCTAssertEqual(svc.env["FROM_FILE"], "file")
        XCTAssertEqual(svc.env["SHARED"], "env")   // environment: wins over env_file
        XCTAssertNil(svc.env["not a pair"])
    }

    func testMissingEnvFileWarnsAndContinues() throws {
        let (stack, warnings) = try translate("""
        services:
          web:
            image: img
            env_file: /nonexistent/podium-test.env
        """)
        XCTAssertEqual(stack.services.count, 1)
        XCTAssertTrue(warnings.contains { $0.contains("env_file") && $0.contains("not found") })
    }

    // MARK: depends_on (list | dict)

    func testDependsOnListAndDict() throws {
        let svcList = try service("""
        services:
          web: {image: img, depends_on: [db, cache]}
          db: {image: pg}
          cache: {image: redis}
        """)
        XCTAssertEqual(svcList.dependsOn, ["db", "cache"])

        let svcDict = try service("""
        services:
          web:
            image: img
            depends_on:
              db: {condition: service_healthy}
              cache: {condition: service_started}
          db: {image: pg}
          cache: {image: redis}
        """)
        XCTAssertEqual(svcDict.dependsOn, ["cache", "db"])   // dict keys → sorted
    }

    // MARK: healthcheck forms

    func testHealthcheckStringForm() throws {
        let svc = try service("""
        services:
          web:
            image: img
            healthcheck: {test: curl -f localhost}
        """)
        XCTAssertEqual(svc.healthCheck, ["/bin/sh", "-c", "curl -f localhost"])
    }

    func testHealthcheckCMDForm() throws {
        let svc = try service("""
        services:
          web:
            image: img
            healthcheck: {test: [CMD, curl, -f, localhost]}
        """)
        XCTAssertEqual(svc.healthCheck, ["curl", "-f", "localhost"])
    }

    func testHealthcheckCMDShellForm() throws {
        let svc = try service("""
        services:
          web:
            image: img
            healthcheck: {test: [CMD-SHELL, curl -f localhost || exit 1]}
        """)
        XCTAssertEqual(svc.healthCheck, ["/bin/sh", "-c", "curl -f localhost || exit 1"])
    }

    func testHealthcheckNoneAndBareArray() throws {
        let none = try service("""
        services:
          web:
            image: img
            healthcheck: {test: [NONE]}
        """)
        XCTAssertNil(none.healthCheck)

        let bare = try service("""
        services:
          web:
            image: img
            healthcheck: {test: [curl, localhost]}
        """)
        XCTAssertEqual(bare.healthCheck, ["curl", "localhost"])
    }

    // MARK: healthcheck probe tuning

    func testHealthcheckTuningMapsToProbeFields() throws {
        let svc = try service("""
        services:
          web:
            image: img
            healthcheck:
              test: [CMD, curl, -f, localhost]
              interval: 30s
              retries: 5
              start_period: 1m30s
        """)
        XCTAssertEqual(svc.livenessIntervalSeconds, 30)
        XCTAssertEqual(svc.livenessFailThreshold, 5)
        XCTAssertEqual(svc.healthTimeoutSeconds, 90)
    }

    func testHealthcheckTuningDefaultsWhenAbsent() throws {
        let svc = try service("""
        services:
          web:
            image: img
            healthcheck: {test: [CMD, true]}
        """)
        XCTAssertNil(svc.livenessIntervalSeconds, "nil → daemon default")
        XCTAssertNil(svc.livenessFailThreshold, "nil → daemon default")
        XCTAssertEqual(svc.healthTimeoutSeconds, 60)
    }

    func testHealthcheckTimeoutWarnsAndBadDurationsFallBack() throws {
        let (stack, warnings) = try translate("""
        services:
          web:
            image: img
            healthcheck:
              test: [CMD, true]
              interval: soon
              timeout: 5s
        """)
        let svc = stack.services[0]
        XCTAssertNil(svc.livenessIntervalSeconds, "unparseable interval falls back to default")
        XCTAssertTrue(warnings.contains { $0.contains("healthcheck.timeout") },
                      "unsupported timeout must be a visible warning, not a silent drop")
        XCTAssertTrue(warnings.contains { $0.contains("healthcheck.interval") })
    }

    // MARK: restart mapping

    func testRestartMapping() throws {
        func policy(_ restart: String?) throws -> RestartPolicy {
            let yaml = restart.map { "services:\n  web: {image: img, restart: \"\($0)\"}\n" }
                ?? "services:\n  web: {image: img}\n"
            return try service(yaml).restartPolicy
        }
        XCTAssertEqual(try policy("always"), .always)
        // Documented divergence: Podium currently normalizes unless-stopped to always.
        XCTAssertEqual(try policy("unless-stopped"), .always)
        XCTAssertEqual(try policy("on-failure"), .onFailure)
        XCTAssertEqual(try policy("no"), .no)
        XCTAssertEqual(try policy(nil), .no)   // compose default is "no"
    }

    // MARK: resources — mem_limit / deploy limits / cpus precedence

    func testMemoryPrecedenceDirectWinsOverDeploy() throws {
        let svc = try service("""
        services:
          web:
            image: img
            mem_limit: 256m
            deploy: {resources: {limits: {memory: 1g}}}
        """)
        XCTAssertEqual(svc.memoryMB, 256)
    }

    func testDeployLimitsAloneApply() throws {
        let svc = try service("""
        services:
          web:
            image: img
            deploy: {resources: {limits: {memory: 1g, cpus: "1.5"}}}
        """)
        XCTAssertEqual(svc.memoryMB, 1024)
        XCTAssertEqual(svc.cpus, 2)   // ceil(1.5)
    }

    func testCpusDirectWinsAndRoundsUp() throws {
        let svc = try service("""
        services:
          web:
            image: img
            cpus: 0.5
            deploy: {resources: {limits: {cpus: "4"}}}
        """)
        XCTAssertEqual(svc.cpus, 1)   // ceil(0.5) clamped to ≥ 1
    }

    func testParseMB() {
        XCTAssertEqual(parseMB("512m"), 512)
        XCTAssertEqual(parseMB("512MB"), 512)
        XCTAssertEqual(parseMB("1g"), 1024)
        XCTAssertEqual(parseMB("1.5g"), 1536)
        XCTAssertEqual(parseMB("2gb"), 2048)
        XCTAssertEqual(parseMB("268435456"), 256)   // bare bytes
        XCTAssertNil(parseMB("lots"))
    }

    // MARK: x-podium overlay (highest precedence)

    func testXPodiumOverlayWins() throws {
        let svc = try service("""
        services:
          web:
            image: img
            mem_limit: 256m
            cpus: 1
            x-podium:
              memoryMB: 2048
              cpus: 3
              rootfsGB: 4
              secrets: {DB_PASS: db_pass}
        """)
        XCTAssertEqual(svc.memoryMB, 2048)
        XCTAssertEqual(svc.cpus, 3)
        XCTAssertEqual(svc.rootfsGB, 4)
        XCTAssertEqual(svc.secrets, ["DB_PASS": "db_pass"])
    }

    // MARK: volumes

    func testBindMountShortForm() throws {
        let svc = try service("""
        services:
          web:
            image: img
            volumes:
              - ./html:/usr/share/nginx/html:ro
              - /var/data:/data
        """)
        XCTAssertEqual(svc.volumes[0].source, "./html")
        XCTAssertEqual(svc.volumes[0].destination, "/usr/share/nginx/html")
        XCTAssertTrue(svc.volumes[0].readOnly)
        XCTAssertEqual(svc.volumes[1].source, "/var/data")
        XCTAssertFalse(svc.volumes[1].readOnly)
    }

    func testBindMountOptionHintsIgnored() throws {
        let svc = try service("""
        services:
          web:
            image: img
            volumes: ["/src:/dst:cached,ro,z"]
        """)
        XCTAssertTrue(svc.volumes[0].readOnly)          // ro honored
        XCTAssertEqual(svc.volumes[0].source, "/src")   // cached/z silently dropped
    }

    func testNamedVolumeDeclared() throws {
        // `pgdata:` with a null body is the common spelling — exercises the
        // double-optional decl lookup.
        let svc = try service("""
        services:
          web:
            image: img
            volumes: ["pgdata:/var/lib/postgresql/data"]
        volumes:
          pgdata:
        """)
        XCTAssertEqual(svc.volumes[0].name, "pgdata")
        XCTAssertNil(svc.volumes[0].source)
        XCTAssertEqual(svc.volumes[0].destination, "/var/lib/postgresql/data")
    }

    func testUndeclaredNamedVolumeThrows() {
        XCTAssertThrowsError(try translate("""
        services:
          web:
            image: img
            volumes: ["pgdata:/data"]
        """)) { err in
            guard case ComposeError.undeclaredVolume(let s, let n) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(s, "web"); XCTAssertEqual(n, "pgdata")
        }
    }

    func testExternalVolumeThrows() {
        XCTAssertThrowsError(try translate("""
        services:
          web: {image: img, volumes: ["shared:/data"]}
        volumes:
          shared: {external: true}
        """)) { err in
            guard case ComposeError.externalVolumeUnsupported = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testNonLocalDriverThrows() {
        XCTAssertThrowsError(try translate("""
        services:
          web: {image: img, volumes: ["nfsdata:/data"]}
        volumes:
          nfsdata: {driver: nfs}
        """)) { err in
            guard case ComposeError.volumeDriverUnsupported(_, let d) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(d, "nfs")
        }
    }

    func testAnonymousVolumesGetStableDerivedNames() throws {
        let yaml = """
        services:
          db:
            image: mysql
            volumes:
              - /var/lib/mysql
              - {target: /var/log/mysql}
        """
        let a = try service(yaml, "db")
        let b = try service(yaml, "db")
        // anonymous → managed volume named <svc>-<hash(dst)>; deterministic
        XCTAssertEqual(a.volumes.map { $0.name }, b.volumes.map { $0.name })
        XCTAssertTrue(a.volumes[0].name!.hasPrefix("db-"))
        XCTAssertNil(a.volumes[0].source)
        XCTAssertNotEqual(a.volumes[0].name, a.volumes[1].name)   // distinct per destination
        XCTAssertEqual(a.volumes[1].destination, "/var/log/mysql")
    }

    func testLongFormVolume() throws {
        let svc = try service("""
        services:
          web:
            image: img
            volumes:
              - {source: /host/path, target: /container, read_only: true}
        """)
        XCTAssertEqual(svc.volumes[0].source, "/host/path")
        XCTAssertEqual(svc.volumes[0].destination, "/container")
        XCTAssertTrue(svc.volumes[0].readOnly)
    }

    // MARK: ports — short forms, bind IP, publish opt-in

    func testPortShortForms() throws {
        let svc = try service("""
        services:
          web:
            image: img
            ports:
              - "80"
              - "443/tcp"
              - "8080:80"
              - "127.0.0.1:9090:90"
        """)
        let pf = svc.portForwards
        XCTAssertEqual(pf.count, 4)
        XCTAssertEqual(pf[0], PortForward(host: 80, container: 80))
        XCTAssertEqual(pf[1], PortForward(host: 443, container: 443))     // proto stripped
        XCTAssertEqual(pf[2], PortForward(host: 8080, container: 80))
        XCTAssertEqual(pf[3].bindAddress, "127.0.0.1")                    // Honored, not widened
        XCTAssertEqual(pf[3].hostPort, 9090)
        XCTAssertEqual(pf[3].containerPort, 90)
        // secure-by-default: everything above is loopback
        XCTAssertTrue(pf.allSatisfy { $0.bindAddress == "127.0.0.1" })
    }

    func testPortLongForm() throws {
        let svc = try service("""
        services:
          web:
            image: img
            ports:
              - {target: 80, published: "8080", host_ip: 10.0.0.5}
              - {target: 90}
        """)
        XCTAssertEqual(svc.portForwards[0], PortForward(host: 8080, container: 80, bindAddress: "10.0.0.5"))
        XCTAssertEqual(svc.portForwards[1], PortForward(host: 90, container: 90))
    }

    func testPublishOptInWidensDefaultBindOnly() throws {
        let (stack, warnings) = try translate("""
        services:
          web:
            image: img
            x-podium: {publish: true}
            ports:
              - "8080:80"
              - "127.0.0.1:9090:90"
        """)
        let pf = stack.services[0].portForwards
        XCTAssertEqual(pf[0].bindAddress, "0.0.0.0")     // publish applies to default…
        XCTAssertEqual(pf[1].bindAddress, "127.0.0.1")   // …explicit IPs stay as written
        XCTAssertFalse(warnings.contains { $0.contains("bind loopback by default") })
    }

    func testLoopbackDefaultWarnsHowToPublish() throws {
        let (_, warnings) = try translate("""
        services:
          web: {image: img, ports: ["8080:80"]}
        """)
        XCTAssertTrue(warnings.contains { $0.contains("bind loopback by default") },
                      "expected publish hint, got: \(warnings)")
    }

    // MARK: variable interpolation

    func testInterpolationForms() throws {
        let values = ["SET": "v", "EMPTY": ""]
        func interp(_ s: String) throws -> String {
            try interpolateComposeVars(s, values: values).text
        }
        XCTAssertEqual(try interp("${SET}"), "v")
        XCTAssertEqual(try interp("x$SET/y"), "xv/y")            // bare $VAR
        XCTAssertEqual(try interp("${UNSET:-def}"), "def")
        XCTAssertEqual(try interp("${EMPTY:-def}"), "def")       // :- treats empty as unset
        XCTAssertEqual(try interp("${EMPTY-def}"), "")           // -  keeps set-but-empty
        XCTAssertEqual(try interp("${UNSET-def}"), "def")
        XCTAssertEqual(try interp("$$SET"), "$SET")              // $$ → literal $
        XCTAssertEqual(try interp("cost: $5"), "cost: $5")       // lone $ passthrough
        XCTAssertEqual(try interp("${SET:?msg}"), "v")
        XCTAssertEqual(try interp("${EMPTY?msg}"), "")           // ? only fails when unset
    }

    func testInterpolationUnsetSubstitutesEmptyWithWarning() throws {
        let (text, warnings) = try interpolateComposeVars("a=${NOPE} b=$ALSO_NOPE", values: [:])
        XCTAssertEqual(text, "a= b=")
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings[0].contains("NOPE"))
    }

    func testInterpolationRequiredThrows() {
        XCTAssertThrowsError(try interpolateComposeVars("${MUST:?database url required}", values: [:])) { err in
            guard case ComposeError.requiredVariable(let n, let m) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(n, "MUST")
            XCTAssertEqual(m, "database url required")
        }
        // :? also rejects set-but-empty
        XCTAssertThrowsError(try interpolateComposeVars("${E:?msg}", values: ["E": ""]))
    }

    func testInterpolationMalformedThrows() {
        XCTAssertThrowsError(try interpolateComposeVars("${", values: [:]))          // unterminated
        XCTAssertThrowsError(try interpolateComposeVars("${1BAD}", values: [:]))     // bad name start
        XCTAssertThrowsError(try interpolateComposeVars("${NAME!}", values: [:]))    // junk after name
    }

    func testInterpolationEndToEndThroughYAML() throws {
        let (text, _) = try interpolateComposeVars("""
        services:
          web:
            image: nginx:${TAG:-latest}
            environment:
              GREETING: hello $NAME
        """, values: ["NAME": "world"])
        let compose = try YAMLDecoder().decode(ComposeFile.self, from: text)
        let (stack, _) = try compose.toStack(projectName: "p")
        XCTAssertEqual(stack.services[0].image, "nginx:latest")
        XCTAssertEqual(stack.services[0].env["GREETING"], "hello world")
    }

    func testParseDotEnv() {
        let env = parseDotEnv("""
        # comment
        PLAIN=value
        QUOTED="with spaces"
        SINGLE='single'
        EQ=a=b
        BROKEN LINE
        """)
        XCTAssertEqual(env["PLAIN"], "value")
        XCTAssertEqual(env["QUOTED"], "with spaces")
        XCTAssertEqual(env["SINGLE"], "single")
        XCTAssertEqual(env["EQ"], "a=b")
        XCTAssertEqual(env.count, 4)
    }

    // MARK: loadCompose end-to-end (project name, .env wiring, process-env override)

    func testLoadComposeProjectNameAndDotEnv() throws {
        unsetenv("TAG")   // don't let a host-environment TAG shadow the .env value
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Podium Test (copy) \(Int.random(in: 100...999))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "TAG=from-dotenv\n".write(to: dir.appendingPathComponent(".env"),
                                      atomically: true, encoding: .utf8)
        let composePath = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          web:
            image: nginx:${TAG}
        """.write(to: composePath, atomically: true, encoding: .utf8)

        // .env value applies…
        let stack = try Stack.loadCompose(composePath.path)
        XCTAssertEqual(stack.services[0].image, "nginx:from-dotenv")
        // …directory-derived project name is normalized into the valid charset
        XCTAssertEqual(stack.name, Stack.normalizeName(dir.lastPathComponent))
        XCTAssertTrue(Stack.isValidName(stack.name))

        // process env overrides .env (docker compose precedence)
        setenv("TAG", "from-process", 1)
        defer { unsetenv("TAG") }
        let stack2 = try Stack.loadCompose(composePath.path)
        XCTAssertEqual(stack2.services[0].image, "nginx:from-process")
    }

    func testLoadComposeHonorsExplicitName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let composePath = dir.appendingPathComponent("compose.yaml")
        try "name: myproj\nservices:\n  web: {image: img}\n"
            .write(to: composePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Stack.loadCompose(composePath.path).name, "myproj")
    }
}
