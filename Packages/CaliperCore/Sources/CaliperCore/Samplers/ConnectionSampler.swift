import CoreWLAN
import Darwin
import Foundation

/// Local addresses and Wi-Fi signal quality.
///
/// Stateless, and the most expensive read per byte of output in the app —
/// `getifaddrs` walks a linked list and the CoreWLAN calls cross to another
/// process — so the cadence table runs it in tens of seconds.
struct ConnectionSampler {
    func sample() -> ConnectionSample {
        ConnectionSample(addresses: localAddresses(), wifi: wifi())
    }

    private func localAddresses() -> [ConnectionSample.InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [ConnectionSample.InterfaceAddress] = []
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = entry.pointee.ifa_addr else { continue }
            let family = socketAddress.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            // An interface that is down still has an address; it is not one the
            // user can be reached at.
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(socketAddress.pointee.sa_len)
            guard
                getnameinfo(
                    socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                ) == 0
            else { continue }

            // Link-local IPv6 addresses carry a %interface suffix that is noise
            // in a panel.
            let address = CString.string(host)
            addresses.append(
                ConnectionSample.InterfaceAddress(
                    interfaceName: CString.string(entry.pointee.ifa_name),
                    address: address.split(separator: "%").first.map(String.init) ?? address,
                    isIPv6: family == UInt8(AF_INET6)
                )
            )
        }
        return addresses
    }

    private func wifi() -> ConnectionSample.WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface(),
            let name = interface.interfaceName,
            interface.powerOn()
        else { return nil }

        let channel = interface.wlanChannel()
        return ConnectionSample.WiFiInfo(
            interfaceName: name,
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            transmitRateMbps: interface.transmitRate(),
            channel: channel?.channelNumber ?? 0,
            band: Self.band(of: channel?.channelBand)
        )
    }

    private static func band(of band: CWChannelBand?) -> ConnectionSample.WiFiInfo.Band {
        switch band {
        case .band2GHz: .ghz2_4
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: .unknown
        }
    }
}
