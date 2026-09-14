import Foundation
import Network

/// Ping/traceroute/DNS shell out to the system binaries rather than
/// reimplementing ICMP or DNS resolution from scratch — raw ICMP sockets
/// need extra entitlements on macOS, and `dig`'s output format is one every
/// network engineer already reads daily. Port scanning uses Network.framework
/// directly since a TCP connect-scan doesn't need raw sockets. Subnet math
/// is pure Swift, no I/O at all.
///
/// NOTE: shelling out to /sbin/ping, /usr/sbin/traceroute, /usr/bin/dig
/// requires the app NOT be sandboxed (or have the right entitlement) —
/// same App Sandbox tradeoff noted in the README for Serial/Telnet.
enum NetworkTools {
    struct ProcessResult {
        let output: String
        let succeeded: Bool
    }

    private static func run(_ path: String, _ args: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessResult(
                    output: "Failed to launch \(path): \(error.localizedDescription)",
                    succeeded: false
                ))
                return
            }

            let handle = pipe.fileHandleForReading
            var collected = Data()
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    fh.readabilityHandler = nil
                } else {
                    collected.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                collected.append(handle.readDataToEndOfFile())
                let text = String(data: collected, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessResult(output: text, succeeded: proc.terminationStatus == 0))
            }
        }
    }

    static func ping(host: String, count: Int = 4) async -> ProcessResult {
        await run("/sbin/ping", ["-c", "\(count)", host])
    }

    static func traceroute(host: String) async -> ProcessResult {
        await run("/usr/sbin/traceroute", [host])
    }

    static func dnsLookup(host: String) async -> ProcessResult {
        await run("/usr/bin/dig", ["+noall", "+answer", host])
    }

    /// TCP connect-scan for one port — completes a full handshake, so it's
    /// slower and more visible than a SYN scan, but needs no raw-socket
    /// entitlement and no external binary.
    static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval = 2.0) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 0,
                using: .tcp
            )
            var didResume = false
            let resumeOnce: (Bool) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                case .failed, .cancelled:
                    resumeOnce(false)
                default:
                    break
                }
            }

            connection.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce(false)
            }
        }
    }

    static func scanPorts(host: String, ports: [UInt16]) async -> [UInt16: Bool] {
        await withTaskGroup(of: (UInt16, Bool).self) { group in
            for port in ports {
                group.addTask { (port, await isPortOpen(host: host, port: port)) }
            }
            var results: [UInt16: Bool] = [:]
            for await (port, open) in group {
                results[port] = open
            }
            return results
        }
    }

    // MARK: - Subnet calculator (pure math, no I/O — safe to trust as-is)

    struct SubnetInfo {
        let networkAddress: String
        let broadcastAddress: String
        let firstUsableHost: String
        let lastUsableHost: String
        let usableHostCount: Int
        let subnetMask: String
        let cidr: Int
    }

    static func subnetInfo(cidrString: String) -> SubnetInfo? {
        let parts = cidrString.split(separator: "/")
        guard parts.count == 2,
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength),
              let ipInt = ipv4ToUInt32(String(parts[0])) else {
            return nil
        }

        let maskInt: UInt32 = prefixLength == 0 ? 0 : (0xFFFFFFFF << (32 - prefixLength))
        let networkInt = ipInt & maskInt
        let broadcastInt = networkInt | ~maskInt

        let usableCount = prefixLength >= 31 ? 0 : Int(broadcastInt - networkInt) - 1
        let firstHost = prefixLength >= 31 ? networkInt : networkInt + 1
        let lastHost = prefixLength >= 31 ? broadcastInt : broadcastInt - 1

        return SubnetInfo(
            networkAddress: uint32ToIPv4(networkInt),
            broadcastAddress: uint32ToIPv4(broadcastInt),
            firstUsableHost: uint32ToIPv4(firstHost),
            lastUsableHost: uint32ToIPv4(lastHost),
            usableHostCount: max(usableCount, 0),
            subnetMask: uint32ToIPv4(maskInt),
            cidr: prefixLength
        )
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    }

    private static func uint32ToIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
