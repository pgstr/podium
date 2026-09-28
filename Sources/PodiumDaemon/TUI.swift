import Foundation

public enum TUIAction: Equatable, Sendable {
    case selectNext
    case selectPrevious
    case refresh
    case start
    case stop
    case restart
    case reload
    case quit
}

public enum TUIKey {
    public static func action(for byte: UInt8) -> TUIAction? {
        switch byte {
        case UInt8(ascii: "j"): .selectNext
        case UInt8(ascii: "k"): .selectPrevious
        case UInt8(ascii: "u"): .refresh
        case UInt8(ascii: "a"): .start
        case UInt8(ascii: "s"): .stop
        case UInt8(ascii: "r"): .restart
        case UInt8(ascii: "l"): .reload
        case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03, 0x04: .quit
        default: nil
        }
    }
}

public struct TUIState: Sendable {
    public let stack: String
    public private(set) var services: [ServiceStatus]
    public private(set) var selectedIndex: Int
    public private(set) var logLines: [String]
    public private(set) var message: String

    private var pendingLog = Data()
    private let maxLogLines: Int

    public init(stack: String, services: [ServiceStatus], maxLogLines: Int = 200) {
        self.stack = stack
        self.services = services
        self.selectedIndex = 0
        self.logLines = []
        self.message = "connected"
        self.maxLogLines = max(1, maxLogLines)
    }

    public var selectedService: ServiceStatus? {
        services.indices.contains(selectedIndex) ? services[selectedIndex] : nil
    }

    public mutating func replaceServices(_ replacement: [ServiceStatus]) {
        let selectedID = selectedService?.id
        services = replacement
        if let selectedID, let index = services.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(0, services.count - 1))
        }
    }

    public mutating func moveSelection(by delta: Int) {
        guard !services.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(0, selectedIndex + delta), services.count - 1)
    }

    public mutating func clearLogs() {
        logLines.removeAll(keepingCapacity: true)
        pendingLog.removeAll(keepingCapacity: true)
    }

    public mutating func appendLogChunk(_ data: Data) {
        pendingLog.append(data)
        while let newline = pendingLog.firstIndex(of: 0x0a) {
            let bytes = pendingLog[..<newline]
            appendLine(String(decoding: bytes, as: UTF8.self))
            pendingLog.removeSubrange(...newline)
        }
        // A service can emit an unbounded line. Keep the dashboard bounded.
        if pendingLog.count > 64 * 1024 {
            appendLine(String(decoding: pendingLog, as: UTF8.self))
            pendingLog.removeAll(keepingCapacity: true)
        }
    }

    public mutating func setMessage(_ value: String) {
        message = TUIRender.sanitize(value)
    }

    private mutating func appendLine(_ value: String) {
        logLines.append(TUIRender.sanitize(value))
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }
}

public enum TUIRender {
    public static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            if scalar.value == 0x09 || scalar.value >= 0x20 && scalar.value != 0x7f {
                return Character(String(scalar))
            }
            return " "
        })
    }

    public static func frame(
        _ state: TUIState, width requestedWidth: Int, height requestedHeight: Int
    ) -> String {
        let width = max(60, requestedWidth)
        let height = max(12, requestedHeight)
        var lines = [
            fit("PODIUM  \(state.stack)", width: width),
            fit("j/k select  a start  s stop  r restart  l reload  u refresh  q quit", width: width),
            String(repeating: "─", count: width),
        ]

        let addressWidth = max(8, width - 53)
        lines.append(fit(
            "  " + pad("SERVICE", 22) + pad("STATE", 11) + pad("READY", 7)
                + pad("STARTS", 8) + pad("ADDRESS", addressWidth),
            width: width))

        let tableCapacity = max(1, min(state.services.count, height / 2 - 4))
        let selected = state.selectedIndex
        let maxStart = max(0, state.services.count - tableCapacity)
        let start = min(max(0, selected - tableCapacity / 2), maxStart)
        for index in start..<min(state.services.count, start + tableCapacity) {
            let service = state.services[index]
            let marker = index == selected ? "› " : "  "
            let address = serviceAddress(service)
            lines.append(fit(
                marker + pad(service.id, 22) + pad(service.state, 11)
                    + pad(service.ready ? "yes" : "no", 7)
                    + pad(String(service.starts), 8) + pad(address, addressWidth),
                width: width))
        }
        if state.services.isEmpty { lines.append("  (no services)") }

        let selectedName = state.selectedService?.id ?? "—"
        lines.append(String(repeating: "─", count: width))
        lines.append(fit("LOG  \(selectedName)  (latest)", width: width))

        let logCapacity = max(1, height - lines.count - 2)
        let visibleLogs = state.logLines.suffix(logCapacity)
        if visibleLogs.isEmpty {
            lines.append("  (no log output)")
        } else {
            lines.append(contentsOf: visibleLogs.map { fit($0, width: width) })
        }
        while lines.count < height - 1 { lines.append("") }
        lines.append(fit("STATUS  \(state.message)", width: width))
        return lines.prefix(height).joined(separator: "\r\n")
    }

    private static func serviceAddress(_ service: ServiceStatus) -> String {
        guard let ip = service.ip else { return "—" }
        guard !service.portForwards.isEmpty else { return ip }
        return service.portForwards.map {
            "\($0.bindDisplay):\($0.hostPort)→\(ip):\($0.containerPort)"
        }.joined(separator: " ")
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        let value = fit(value, width: width)
        return value + String(repeating: " ", count: max(0, width - value.count))
    }

    private static func fit(_ value: String, width: Int) -> String {
        guard value.count > width else { return value }
        guard width > 1 else { return String(value.prefix(width)) }
        return String(value.prefix(width - 1)) + "…"
    }
}
