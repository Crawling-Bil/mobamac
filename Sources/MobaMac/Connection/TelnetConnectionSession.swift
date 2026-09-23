import Foundation
import Network

/// A raw Telnet client over Network.framework. There's no Citadel
/// equivalent for Telnet (per the PRD's architecture notes) so this talks
/// TCP directly and implements just enough of RFC 854's option-negotiation
/// framing to stay usable against real devices: every negotiation request
/// (WILL/DO) gets a blanket refusal (DONT/WONT), which pushes most servers
/// into plain pass-through instead of hanging on a handshake this client
/// doesn't fully implement. Good enough for the legacy-device-access use
/// case this exists for; not a general-purpose Telnet stack.
final class TelnetConnectionSession: ConnectionSession {
    var onOutput: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "MobaMac.Telnet")

    /// IAC (0xFF) command byte constants from RFC 854.
    private enum Telnet {
        static let iac: UInt8 = 255
        static let will: UInt8 = 251
        static let wont: UInt8 = 252
        static let doCmd: UInt8 = 253
        static let dont: UInt8 = 254
    }

    private enum ParseState {
        case data
        case sawIAC
        case sawCommand(UInt8)
    }
    private var parseState: ParseState = .data

    enum TelnetError: LocalizedError {
        case connectionCancelled

        var errorDescription: String? {
            "The Telnet connection was closed before it finished connecting."
        }
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: max(0, port))
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 23,
                using: .tcp
            )
            self.connection = conn

            var didResume = false
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !didResume else { return }
                    didResume = true
                    self.receiveLoop()
                    continuation.resume()
                case .failed(let error):
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    } else {
                        self.onClose?(error)
                    }
                case .cancelled:
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: TelnetError.connectionCancelled)
                    } else {
                        self.onClose?(nil)
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let clean = self.stripTelnetCommands(data)
                if !clean.isEmpty {
                    self.onOutput?(clean)
                }
            }
            if let error {
                self.onClose?(error)
                return
            }
            if isComplete {
                self.onClose?(nil)
                return
            }
            self.receiveLoop()
        }
    }

    /// Strips IAC option-negotiation sequences out of incoming bytes and
    /// queues a blanket-refusal reply for each one, returning only the
    /// plain data meant for the terminal.
    private func stripTelnetCommands(_ data: Data) -> Data {
        var output = Data()
        var replies = Data()

        for byte in data {
            switch parseState {
            case .data:
                if byte == Telnet.iac {
                    parseState = .sawIAC
                } else {
                    output.append(byte)
                }
            case .sawIAC:
                switch byte {
                case Telnet.iac:
                    output.append(Telnet.iac) // escaped literal 0xFF
                    parseState = .data
                case Telnet.will, Telnet.wont, Telnet.doCmd, Telnet.dont:
                    parseState = .sawCommand(byte)
                default:
                    // Other IAC commands (SB/SE/NOP/etc.) — no trailing
                    // option byte we need to track; drop and move on.
                    parseState = .data
                }
            case .sawCommand(let command):
                switch command {
                case Telnet.doCmd:
                    replies.append(contentsOf: [Telnet.iac, Telnet.wont, byte])
                case Telnet.will:
                    replies.append(contentsOf: [Telnet.iac, Telnet.dont, byte])
                default:
                    break // WONT/DONT from the server need no reply
                }
                parseState = .data
            }
        }

        if !replies.isEmpty {
            Task { await self.rawSend(replies) }
        }
        return output
    }

    func send(_ data: Data) async {
        await rawSend(data)
    }

    private func rawSend(_ data: Data) async {
        guard let connection else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func resize(cols: Int, rows: Int) async {
        // NAWS (option 31) isn't implemented. The legacy devices this targets
        // doesn't renegotiate terminal size mid-session in practice.
    }

    func close() async {
        connection?.cancel()
    }
}
