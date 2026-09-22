import SwiftUI

/// Ping / Traceroute / DNS lookup / Port scanner / Subnet calculator in one
/// panel — no more alt-tabbing to separate utilities mid-session.
struct NetworkToolsView: View {
    enum Tool: String, CaseIterable, Identifiable {
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

    @State private var tool: Tool = .ping
    @State private var host = ""
    @State private var portRange = "22,80,443"
    @State private var cidrInput = "192.168.1.0/24"
    @State private var output = ""
    @State private var isRunning = false
    @State private var subnetResult: NetworkTools.SubnetInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Done") { dismiss() }
            }

            if tool == .subnet {
                HStack {
                    TextField("CIDR, e.g. 192.168.1.0/24", text: $cidrInput)
                        .onSubmit(calculateSubnet)
                    Button("Calculate", action: calculateSubnet)
                }
                if let info = subnetResult {
                    subnetResultView(info)
                } else {
                    Text("Enter a CIDR block and calculate.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                HStack {
                    TextField("Host or IP", text: $host)
                        .onSubmit(runCurrentTool)
                    if tool == .portScan {
                        TextField("Ports, comma-separated", text: $portRange)
                            .frame(width: 180)
                    }
                    Button(isRunning ? "Running…" : "Run", action: runCurrentTool)
                        .disabled(isRunning || host.isEmpty)
                }

                ScrollView {
                    Text(output)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 260)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
    }

    private func runCurrentTool() {
        guard !host.isEmpty else { return }
        isRunning = true
        output = ""
        Task {
            switch tool {
            case .ping:
                output = await NetworkTools.ping(host: host).output
            case .traceroute:
                output = await NetworkTools.traceroute(host: host).output
            case .dns:
                output = await NetworkTools.dnsLookup(host: host).output
            case .portScan:
                let ports = portRange
                    .split(separator: ",")
                    .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
                let results = await NetworkTools.scanPorts(host: host, ports: ports)
                output = results
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value ? "open" : "closed")" }
                    .joined(separator: "\n")
            case .subnet:
                break
            }
            isRunning = false
        }
    }

    private func calculateSubnet() {
        subnetResult = NetworkTools.subnetInfo(cidrString: cidrInput)
    }

    private func subnetResultView(_ info: NetworkTools.SubnetInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Network", info.networkAddress)
            row("Broadcast", info.broadcastAddress)
            row("Subnet Mask", info.subnetMask)
            row("Usable Range", "\(info.firstUsableHost) – \(info.lastUsableHost)")
            row("Usable Hosts", "\(info.usableHostCount)")
            row("CIDR", "/\(info.cidr)")
        }
        .font(.system(.body, design: .monospaced))
        .padding(.top, 8)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value)
        }
    }
}
