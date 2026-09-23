import Foundation
import SwiftUI

enum NetworkTool: String, CaseIterable, Identifiable, Hashable {
    case ping, traceroute, dns, portScan, subnet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ping: return "Ping"
        case .traceroute: return "Traceroute"
        case .dns: return "DNS Lookup"
        case .portScan: return "Port Scan"
        case .subnet: return "Subnet Calc"
        }
    }
}

/// What one tool remembers between visits: the host it was last pointed at,
/// what it printed, and whether it is still working.
struct NetworkToolState {
    var host: String = ""
    var output: String = ""
    var isRunning: Bool = false
}

/// The state behind the Network Tools panel, deliberately *not* `@State`
/// inside the view.
///
/// Two bugs come from putting it there. A single shared `host`/`output` pair
/// means switching from Ping to Traceroute shows the old ping result, which
/// then vanishes when traceroute runs — so every tool keeps its own
/// `NetworkToolState` here instead. And a view's `@State` dies with the view,
/// so closing the panel threw away every result; this object is owned by
/// ContentView, which means it lives as long as the window does.
final class NetworkToolsModel: ObservableObject {
    @Published var tool: NetworkTool = .ping
    @Published var toolStates: [NetworkTool: NetworkToolState] = [:]
    /// Port Scan's own input, kept out of `NetworkToolState` because no
    /// other tool has a use for it.
    @Published var portRange = "22,80,443"
    /// Subnet Calc takes a CIDR block rather than a host, and produces a
    /// struct rather than text, so it keeps its own pair too.
    @Published var cidrInput = "192.168.1.0/24"
    @Published var subnetResult: NetworkTools.SubnetInfo?

    func state(_ tool: NetworkTool) -> NetworkToolState {
        toolStates[tool] ?? NetworkToolState()
    }

    func hostBinding(for tool: NetworkTool) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.state(tool).host ?? "" },
            set: { [weak self] newValue in
                guard let self else { return }
                var current = self.state(tool)
                current.host = newValue
                self.toolStates[tool] = current
            }
        )
    }

    func run(_ tool: NetworkTool) {
        var current = state(tool)
        guard !current.host.isEmpty, !current.isRunning else { return }
        let host = current.host
        let ports = portRange
            .split(separator: ",")
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }

        current.isRunning = true
        current.output = "Running \(tool.label) on \(host)…"
        toolStates[tool] = current

        Task { @MainActor [weak self] in
            let text: String
            switch tool {
            case .ping:
                text = await NetworkTools.ping(host: host).output
            case .traceroute:
                text = await NetworkTools.traceroute(host: host).output
            case .dns:
                text = await NetworkTools.dnsLookup(host: host).output
            case .portScan:
                let results = await NetworkTools.scanPorts(host: host, ports: ports)
                text = results
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value ? "open" : "closed")" }
                    .joined(separator: "\n")
            case .subnet:
                text = ""
            }
            guard let self else { return }
            // Re-read rather than reuse the copy captured above: the host
            // field stays editable while a run is in flight, and finishing a
            // ping shouldn't undo what was typed in the meantime.
            var finished = self.state(tool)
            finished.isRunning = false
            finished.output = text
            self.toolStates[tool] = finished
        }
    }

    func calculateSubnet() {
        subnetResult = NetworkTools.subnetInfo(cidrString: cidrInput)
    }
}
