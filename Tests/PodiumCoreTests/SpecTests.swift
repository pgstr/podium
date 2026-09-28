import XCTest
@testable import PodiumCore

final class SpecTests: XCTestCase {

    // MARK: helpers

    func svc(_ id: String, image: String = "docker.io/library/alpine:3.21",
             dependsOn: [String] = [], volumes: [VolumeMount] = [],
             schedule: String? = nil) -> ServiceSpec {
        ServiceSpec(id: id, image: image, command: nil, workingDirectory: nil,
                    env: [:], secrets: [:], cpus: 1, memoryMB: 512, rootfsGB: 1,
                    volumes: volumes, dependsOn: dependsOn,
                    healthCheck: nil, restartPolicy: .always, schedule: schedule)
    }

    func decodeService(_ json: String) throws -> ServiceSpec {
        try JSONDecoder().decode(ServiceSpec.self, from: Data(json.utf8))
    }

    func decodeStack(_ json: String) throws -> Stack {
        try JSONDecoder().decode(Stack.self, from: Data(json.utf8))
    }

    // MARK: name rules

    func testValidNames() {
        for good in ["web", "svc-a", "db_1", "a", "a1", "demo", String(repeating: "a", count: 32)] {
            XCTAssertTrue(Stack.isValidName(good), good)
        }
        for bad in ["", "Web", "my stack", "-web", "web-", "_web", "web\"x", "a.b",
                    String(repeating: "a", count: 33)] {
            XCTAssertFalse(Stack.isValidName(bad), bad)
        }
    }

    func testNormalizeName() {
        XCTAssertEqual(Stack.normalizeName("MyApp"), "myapp")
        XCTAssertEqual(Stack.normalizeName("My App!"), "my-app")
        XCTAssertEqual(Stack.normalizeName("--x--"), "x")
        XCTAssertEqual(Stack.normalizeName(""), "stack")
        XCTAssertEqual(Stack.normalizeName("äöü"), "stack")  // non-ASCII maps away entirely
        XCTAssertTrue(Stack.isValidName(Stack.normalizeName("Some Dir Name (copy) 2")))
    }

    // MARK: validate()

    func testValidateRejectsBadStackName() {
        XCTAssertThrowsError(try Stack(name: "My Stack", services: [svc("web")]).validate())
    }

    func testValidateRejectsBadServiceId() {
        XCTAssertThrowsError(try Stack(name: "ok", services: [svc("Web")]).validate())
    }

    func testValidateRejectsDuplicateServiceId() {
        XCTAssertThrowsError(try Stack(name: "ok", services: [svc("web"), svc("web")]).validate()) {
            guard case StackValidationError.duplicateServiceId(id: "web") = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testValidateUnknownDependency() {
        let s = Stack(name: "ok", services: [svc("web", dependsOn: ["ghost"])])
        XCTAssertThrowsError(try s.validate()) { err in
            guard case StackValidationError.unknownDependency = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testValidateCycle() {
        let s = Stack(name: "ok", services: [
            svc("a", dependsOn: ["b"]), svc("b", dependsOn: ["a"]),
        ])
        XCTAssertThrowsError(try s.validate()) { err in
            guard case StackValidationError.cycle = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func testValidateVolumeXor() throws {
        // Neither source nor name → must throw. Build via JSON since the inits enforce XOR.
        let json = #"{"id":"web","image":"x","volumes":[{"destination":"/data"}]}"#
        let spec = try decodeService(json)
        XCTAssertThrowsError(try Stack(name: "ok", services: [spec]).validate())
    }

    func testValidateBadCron() {
        XCTAssertThrowsError(try Stack(name: "ok", services: [svc("job", schedule: "not a cron")]).validate())
        XCTAssertNoThrow(try Stack(name: "ok", services: [svc("job", schedule: "0 3 * * *")]).validate())
    }

    // MARK: decode defaults

    func testServiceDecodeDefaults() throws {
        let s = try decodeService(#"{"id":"web","image":"img"}"#)
        XCTAssertEqual(s.cpus, 1)
        XCTAssertEqual(s.memoryMB, 512)
        XCTAssertEqual(s.rootfsGB, 1)
        XCTAssertEqual(s.restartPolicy, .always)
        XCTAssertEqual(s.healthTimeoutSeconds, 60)
        XCTAssertTrue(s.portForwards.isEmpty)
        XCTAssertNil(s.entrypoint)
        XCTAssertNil(s.command)
        XCTAssertNil(s.args)
    }

    func testSplitProcessFieldsDecodeAndRoundTrip() throws {
        let first = try decodeService(#"{"id":"web","image":"img","entrypoint":["/init"],"command":["worker"],"args":["run"]}"#)
        XCTAssertEqual(first.entrypoint, ["/init"])
        XCTAssertEqual(first.command, ["worker"])
        XCTAssertEqual(first.args, ["run"])

        let second = try JSONDecoder().decode(
            ServiceSpec.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(second, first)
    }

    func testHealthTimeoutDecodes() throws {
        let s = try decodeService(#"{"id":"web","image":"img","healthTimeoutSeconds":5}"#)
        XCTAssertEqual(s.healthTimeoutSeconds, 5)
    }

    // MARK: ports decode

    func testPortIntShorthandIsLoopback() throws {
        let s = try decodeService(#"{"id":"web","image":"img","ports":[8080]}"#)
        XCTAssertEqual(s.portForwards, [PortForward(host: 8080, container: 8080)])
        XCTAssertEqual(s.portForwards[0].bindAddress, "127.0.0.1")
        XCTAssertEqual(s.portForwards[0].bindDisplay, "127.0.0.1")
    }

    func testPortObjectWithBindAddress() throws {
        let s = try decodeService(
            #"{"id":"web","image":"img","ports":[{"hostPort":80,"containerPort":8080,"bindAddress":"0.0.0.0"}]}"#)
        XCTAssertEqual(s.portForwards[0].bindAddress, "0.0.0.0")
        XCTAssertEqual(s.portForwards[0].bindDisplay, "*")
        XCTAssertEqual(s.portForwards[0].hostPort, 80)
        XCTAssertEqual(s.portForwards[0].containerPort, 8080)
    }

    // MARK: spec equality drives reload/diff

    func testSpecChangeDetection() throws {
        var a = try decodeService(#"{"id":"web","image":"img"}"#)
        let b = try decodeService(#"{"id":"web","image":"img"}"#)
        XCTAssertEqual(a, b)
        a.memoryMB = 1024
        XCTAssertNotEqual(a, b)
    }

    // MARK: managed ingress

    func testManagedIngressExpandsToGeneratedCaddyService() throws {
        let stack = try decodeStack(#"""
        {
          "name": "managed",
          "services": [{"id": "app", "image": "docker.io/library/busybox:1.37"}],
          "ingress": {
            "hostPort": 18082,
            "routes": [{"host": "app.home.local", "service": "app", "port": 8080}]
          }
        }
        """#)

        try stack.validate()
        XCTAssertEqual(stack.services.count, 2)
        let ingress = try XCTUnwrap(stack.services.first { $0.id == "podium-ingress" })
        XCTAssertEqual(ingress.image, "docker.io/library/caddy:2-alpine")
        XCTAssertEqual(ingress.dependsOn, ["app"])
        XCTAssertEqual(ingress.portForwards, [PortForward(host: 18082, container: 80)])
        XCTAssertEqual(ingress.healthCheck, ["wget", "-q", "-O-", "http://127.0.0.1:2019/config/"])
        XCTAssertEqual(ingress.livenessCheck, ingress.healthCheck)
        XCTAssertEqual(ingress.env["PODIUM_CADDYFILE"], """
        {
            admin localhost:2019
            auto_https off
        }

        http://app.home.local {
            reverse_proxy app:8080
        }
        """)
    }

    func testManagedIngressSupportsExplicitPublishedBind() throws {
        let stack = try decodeStack(#"""
        {"name":"managed","services":[{"id":"app","image":"img"}],
         "ingress":{"hostPort":80,"bindAddress":"0.0.0.0",
                    "routes":[{"host":"app.home.local","service":"app","port":8080}]}}
        """#)
        let ingress = try XCTUnwrap(stack.services.first { $0.id == "podium-ingress" })
        XCTAssertEqual(ingress.portForwards,
                       [PortForward(host: 80, container: 80, bindAddress: "0.0.0.0")])
    }

    func testManagedIngressEncodingIsNormalizedAndDoesNotExpandTwice() throws {
        let first = try decodeStack(#"""
        {"name":"managed","services":[{"id":"app","image":"img"}],
         "ingress":{"routes":[{"host":"app.home.local","service":"app","port":8080}]}}
        """#)
        let encoded = try JSONEncoder().encode(first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["ingress"])
        XCTAssertEqual((object["services"] as? [Any])?.count, 2)

        let second = try JSONDecoder().decode(Stack.self, from: encoded)
        XCTAssertEqual(second.services.map(\.id).filter { $0 == "podium-ingress" }.count, 1)
    }

    func testManagedIngressRejectsInvalidConfigurations() {
        let invalid = [
            #"{"name":"s","services":[{"id":"app","image":"img"}],"ingress":{"routes":[]}}"#,
            #"{"name":"s","services":[{"id":"app","image":"img"}],"ingress":{"routes":[{"host":"Bad Host","service":"app","port":80}]}}"#,
            #"{"name":"s","services":[{"id":"app","image":"img"}],"ingress":{"routes":[{"host":"app.local","service":"missing","port":80}]}}"#,
            #"{"name":"s","services":[{"id":"app","image":"img"}],"ingress":{"routes":[{"host":"app.local","service":"app","port":0}]}}"#,
            #"{"name":"s","services":[{"id":"app","image":"img"}],"ingress":{"hostPort":0,"routes":[{"host":"app.local","service":"app","port":80}]}}"#,
            #"{"name":"s","services":[{"id":"app","image":"img"}],"ingress":{"routes":[{"host":"app.local","service":"app","port":80},{"host":"app.local","service":"app","port":81}]}}"#,
            #"{"name":"s","services":[{"id":"podium-ingress","image":"img"}],"ingress":{"routes":[{"host":"app.local","service":"podium-ingress","port":80}]}}"#,
            #"{"name":"s","services":[{"id":"app","image":"a"},{"id":"app","image":"b"}],"ingress":{"routes":[{"host":"app.local","service":"app","port":80}]}}"#,
        ]
        for json in invalid {
            XCTAssertThrowsError(try decodeStack(json), json)
        }
    }

    // MARK: managed DNS

    func testManagedDNSExpandsAndMakesServicesDependOnIt() throws {
        let stack = try decodeStack(#"""
        {"name":"discovery","dns":true,
         "services":[{"id":"app","image":"img"},{"id":"worker","image":"img","dependsOn":["app"]}]}
        """#)

        try stack.validate()
        XCTAssertEqual(stack.services.map(\.id), ["podium-dns", "app", "worker"])
        let dns = stack.services[0]
        XCTAssertEqual(dns.image, "docker.io/coredns/coredns:1.12.4")
        XCTAssertEqual(dns.command, ["/coredns", "-conf", "/config/Corefile"])
        XCTAssertEqual(dns.volumes, [VolumeMount(name: "podium-dns-config", destination: "/config")])
        XCTAssertEqual(stack.services[1].dependsOn, ["podium-dns"])
        XCTAssertEqual(stack.services[2].dependsOn, ["app", "podium-dns"])
    }

    func testManagedDNSEncodingIsNormalizedAndDoesNotExpandTwice() throws {
        let first = try decodeStack(#"{"name":"discovery","dns":true,"services":[{"id":"app","image":"img"}]}"#)
        let encoded = try JSONEncoder().encode(first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["dns"])

        let second = try JSONDecoder().decode(Stack.self, from: encoded)
        XCTAssertEqual(second.services.map(\.id).filter { $0 == "podium-dns" }.count, 1)
        XCTAssertEqual(second.services.first { $0.id == "app" }?.dependsOn, ["podium-dns"])
    }

    func testManagedDNSRejectsReservedAndDuplicateServiceIDs() {
        let invalid = [
            #"{"name":"s","dns":true,"services":[{"id":"podium-dns","image":"img"}]}"#,
            #"{"name":"s","dns":true,"services":[{"id":"app","image":"a"},{"id":"app","image":"b"}]}"#,
        ]
        for json in invalid { XCTAssertThrowsError(try decodeStack(json), json) }
    }
}
