import Foundation
import ORSSerial

/// Thin wrapper around ORSSerialPortManager so the UI layer doesn't need to
/// import ORSSerial directly. Call `availablePorts()` fresh each time the
/// picker is shown/refreshed — USB-to-serial adapters come and go, and
/// there's no cheap way to observe that from here without adding KVO
/// plumbing this app doesn't otherwise need.
enum SerialPortLister {
    struct Port: Identifiable, Hashable {
        let path: String
        let name: String

        var id: String { path }
    }

    static func availablePorts() -> [Port] {
        ORSSerialPortManager.shared().availablePorts.map { serialPort in
            Port(path: serialPort.path, name: serialPort.name)
        }
    }
}
