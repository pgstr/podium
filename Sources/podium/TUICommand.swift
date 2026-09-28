import ContainerizationOS
import Darwin
import Foundation
import PodiumDaemon
import PodiumRPC

private enum TUIUpdate: Sendable {
    case key(UInt8)
    case event(PodiumEvent)
    case log(token: UInt64, data: Data)
    case logEnded(token: UInt64, error: String?)
    case eventsEnded(error: String?)
}

private final class TUIMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TUIUpdate] = []

    func post(_ update: TUIUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func drain() -> [TUIUpdate] {
        lock.lock()
        defer { lock.unlock() }
        let drained = updates
        updates.removeAll(keepingCapacity: true)
        return drained
    }
}

private func tuiTerminalSize() -> (width: Int, height: Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else {
        return (100, 30)
    }
    return (max(60, Int(size.ws_col)), max(12, Int(size.ws_row)))
}

private func tuiLogTask(
    socketPath: String, service: String, token: UInt64, mailbox: TUIMailbox
) -> Task<Void, Never> {
    Task.detached {
        do {
            for try await data in ControlPlaneClient.logsStream(
                socketPath: socketPath, service: service,
                tail: 100, sinceUsec: 0, follow: true, previous: false
            ) {
                mailbox.post(.log(token: token, data: data))
            }
            mailbox.post(.logEnded(token: token, error: nil))
        } catch is CancellationError {
            mailbox.post(.logEnded(token: token, error: nil))
        } catch {
            mailbox.post(.logEnded(token: token, error: String(describing: error)))
        }
    }
}

private func tuiEventTask(
    socketPath: String, after: Int, mailbox: TUIMailbox
) -> Task<Void, Never> {
    Task.detached {
        do {
            for try await event in ControlPlaneClient.eventsStream(
                socketPath: socketPath, after: after, follow: true
            ) {
                mailbox.post(.event(event))
            }
            mailbox.post(.eventsEnded(error: nil))
        } catch is CancellationError {
            mailbox.post(.eventsEnded(error: nil))
        } catch {
            mailbox.post(.eventsEnded(error: String(describing: error)))
        }
    }
}

func runTUI(socketPath: String) async -> Int32 {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
        FileHandle.standardError.write(Data(
            "podium: tui requires an interactive terminal\n".utf8))
        return 2
    }

    let initial: (stack: String, services: [ServiceStatus])
    var lastEventSequence = 0
    do {
        initial = try await ControlPlaneClient.listServices(socketPath: socketPath)
        for try await event in ControlPlaneClient.eventsStream(
            socketPath: socketPath, after: 0, follow: false
        ) {
            lastEventSequence = max(lastEventSequence, event.seq)
        }
    } catch let error as ControlPlaneClientError {
        FileHandle.standardError.write(Data("podium: \(error)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data(
            "podium: no daemon at \(socketPath) (is a stack applied?)\n".utf8))
        return 1
    }

    guard let terminal = try? Terminal.current else {
        FileHandle.standardError.write(Data("podium: cannot access terminal\n".utf8))
        return 2
    }
    guard (try? terminal.setraw()) != nil else {
        FileHandle.standardError.write(Data("podium: cannot enter raw terminal mode\n".utf8))
        return 2
    }

    let output = FileHandle.standardOutput
    output.write(Data("\u{1b}[?1049h\u{1b}[?25l".utf8))
    defer {
        output.write(Data("\u{1b}[?25h\u{1b}[?1049l".utf8))
        terminal.tryReset()
    }

    let mailbox = TUIMailbox()
    Thread.detachNewThread {
        var byte = [UInt8](repeating: 0, count: 1)
        while Darwin.read(STDIN_FILENO, &byte, 1) == 1 {
            mailbox.post(.key(byte[0]))
            if TUIKey.action(for: byte[0]) == .quit { break }
        }
    }

    let events = tuiEventTask(
        socketPath: socketPath, after: lastEventSequence, mailbox: mailbox)
    var state = TUIState(stack: initial.stack, services: initial.services)
    var logToken: UInt64 = 0
    var logs: Task<Void, Never>? = nil
    var logActive = false
    var shouldQuit = false
    var exitCode: Int32 = 0
    var dirty = true
    var lastSize = tuiTerminalSize()

    func startSelectedLog() -> Task<Void, Never>? {
        guard let service = state.selectedService else { return nil }
        return tuiLogTask(
            socketPath: socketPath, service: service.id,
            token: logToken, mailbox: mailbox)
    }

    if state.selectedService != nil {
        logToken &+= 1
        logs = startSelectedLog()
        logActive = true
    }

    while !shouldQuit {
        var needsRefresh = false
        var restartSelectedLog = false
        for update in mailbox.drain() {
            switch update {
            case .key(let byte):
                guard let action = TUIKey.action(for: byte) else { continue }
                switch action {
                case .selectNext, .selectPrevious:
                    let before = state.selectedService?.id
                    state.moveSelection(by: action == .selectNext ? 1 : -1)
                    if state.selectedService?.id != before {
                        state.clearLogs()
                        state.setMessage("selected \(state.selectedService?.id ?? "—")")
                        restartSelectedLog = true
                    }
                case .refresh:
                    state.setMessage("refreshing")
                    needsRefresh = true
                case .start, .stop, .restart:
                    guard let service = state.selectedService else { continue }
                    let rpcAction: PbControlRequest.Action = switch action {
                    case .start: .start
                    case .stop: .stop
                    default: .restart
                    }
                    let verb = action == .start ? "start" : action == .stop ? "stop" : "restart"
                    do {
                        let response = try await ControlPlaneClient.control(
                            socketPath: socketPath, action: rpcAction, id: service.id,
                            argv: "\(CommandLine.arguments.joined(separator: " ")) [\(verb)]")
                        state.setMessage(response.ok
                            ? "\(verb) \(service.id): ok"
                            : "\(verb) \(service.id): \(response.error)")
                        needsRefresh = true
                        if response.ok { restartSelectedLog = true }
                    } catch {
                        state.setMessage("\(verb) \(service.id): \(error)")
                    }
                case .reload:
                    do {
                        let diff = try await ControlPlaneClient.reload(
                            socketPath: socketPath, dryRun: false,
                            argv: "\(CommandLine.arguments.joined(separator: " ")) [reload]")
                        let changed = diff.restarted + diff.started + diff.stopped
                        state.setMessage(changed.isEmpty
                            ? "reload: no changes"
                            : "reload: \(changed.joined(separator: ", "))")
                        needsRefresh = true
                    } catch {
                        state.setMessage("reload: \(error)")
                    }
                case .quit:
                    shouldQuit = true
                }
                dirty = true

            case .event(let event):
                let detail = event.detail.map { " — \($0)" } ?? ""
                state.setMessage("\(event.svc): \(event.type)\(detail)")
                needsRefresh = true
                if !logActive, event.svc == state.selectedService?.id {
                    restartSelectedLog = true
                }
                dirty = true

            case .log(let token, let data):
                guard token == logToken else { continue }
                state.appendLogChunk(data)
                dirty = true

            case .logEnded(let token, let error):
                guard token == logToken else { continue }
                logActive = false
                if let error {
                    state.setMessage("logs \(state.selectedService?.id ?? "—"): \(error)")
                    dirty = true
                }

            case .eventsEnded(let error):
                if let error {
                    state.setMessage("event stream ended: \(error)")
                } else {
                    state.setMessage("event stream ended")
                }
                exitCode = 1
                shouldQuit = true
                dirty = true
            }
        }

        if needsRefresh {
            let before = state.selectedService?.id
            do {
                let snapshot = try await ControlPlaneClient.listServices(socketPath: socketPath)
                state.replaceServices(snapshot.services)
                if state.selectedService?.id != before {
                    state.clearLogs()
                    restartSelectedLog = true
                }
            } catch {
                state.setMessage("refresh: \(error)")
            }
            dirty = true
        }

        if restartSelectedLog {
            logs?.cancel()
            logToken &+= 1
            state.clearLogs()
            logs = startSelectedLog()
            logActive = logs != nil
            dirty = true
        }

        let size = tuiTerminalSize()
        if size != lastSize { lastSize = size; dirty = true }
        if dirty {
            let frame = TUIRender.frame(state, width: size.width, height: size.height)
            output.write(Data(("\u{1b}[H\u{1b}[2J" + frame).utf8))
            dirty = false
        }
        if !shouldQuit {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    logs?.cancel()
    events.cancel()
    return exitCode
}
