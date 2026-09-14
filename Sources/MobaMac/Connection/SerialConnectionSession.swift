import Foundation
import ORSSerial

/// Bridges a physical serial console cable (USB-to-serial adapter) to a
/// ConnectionSession — the PRD's use case #2: "console into a switch over
/// serial when it has no IP yet or the network path is down." Built on
/// ORSSerialPort, confirmed against its real header
/// (Sources/include/ORSSerial/ORSSerialPort.h) rather than guessed.
final class SerialConnectionSession: NSObject, ConnectionSession {
    var onOutput: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let devicePath: String
    private let baudRate: Int
    private var port: ORSSerialPort?

    enum SerialError: LocalizedError {
        case deviceNotFound(path: String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let path):
                return "Couldn't open the serial port at \(path). Check the adapter is still plugged in and not already in use by another app or another MobaMac tab."
            }
        }
    }

    init(devicePath: String, baudRate: Int) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        super.init()
    }

    func start() async throws {
        guard let port = ORSSerialPort(path: devicePath) else {
            throw SerialError.deviceNotFound(path: devicePath)
        }
        port.baudRate = NSNumber(value: baudRate)
        port.parity = .none
        port.numberOfStopBits = 1
        port.usesRTSCTSFlowControl = false
        port.delegate = self
        self.port = port
        port.open()
    }

    func send(_ data: Data) async {
        _ = port?.send(data)
    }

    func resize(cols: Int, rows: Int) async {
        // No terminal-size concept over a raw serial link.
    }

    func close() async {
        _ = port?.close()
        port = nil
    }
}

extension SerialConnectionSession: ORSSerialPortDelegate {
    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        self.port = nil
        onClose?(nil)
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        onOutput?(data)
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        onClose?(error)
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        onClose?(nil)
    }
}
