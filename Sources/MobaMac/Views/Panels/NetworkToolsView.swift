import SwiftUI

/// Ping / Traceroute / DNS lookup / Port scanner / Subnet calculator, shown
/// as a right-hand panel beside the terminal rather than a sheet: a sheet is
/// modal, so pinging a gateway used to mean the session behind it was frozen
/// until Done was pressed.
///
/// Holds no state of its own. Everything lives in `NetworkToolsModel`, which
/// the window owns — see the note there for why.
struct NetworkToolsView: View {
    @EnvironmentObject var model: NetworkToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A menu rather than the segmented control this used to be:
            // five labels do not fit across a 380pt panel, and "Traceroute"
            // was the first to be truncated to nothing.
            Picker("Tool", selection: $model.tool) {
                ForEach(NetworkTool.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()

            if model.tool == .subnet {
                subnetSection
            } else {
                runnerSection(for: model.tool)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func runnerSection(for tool: NetworkTool) -> some View {
        let state = model.state(tool)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Host or IP", text: model.hostBinding(for: tool))
                .onSubmit { model.run(tool) }

            if tool == .portScan {
                TextField("Ports, comma-separated", text: $model.portRange)
                    .onSubmit { model.run(tool) }
            }

            Button(state.isRunning ? "Running…" : "Run") {
                model.run(tool)
            }
            .disabled(state.isRunning || state.host.isEmpty)

            ScrollView {
                Text(state.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var subnetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("CIDR, e.g. 192.168.1.0/24", text: $model.cidrInput)
                .onSubmit { model.calculateSubnet() }
            Button("Calculate") { model.calculateSubnet() }

            if let info = model.subnetResult {
                subnetResultView(info)
            } else {
                Text("Enter a CIDR block and calculate.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
        }
    }
}
