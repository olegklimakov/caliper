/// The slow-changing facts about how this Mac is connected.
///
/// Separated from `NetworkSample` because these change when you join a network,
/// not every second, and reading them costs far more than a counter delta.
public struct ConnectionSample: Sendable, Codable, Equatable {
    public let addresses: [InterfaceAddress]
    public let wifi: WiFiInfo?

    public struct InterfaceAddress: Sendable, Codable, Equatable {
        public let interfaceName: String
        public let address: String
        public let isIPv6: Bool
    }

    /// Signal quality of the active Wi-Fi interface.
    ///
    /// No SSID: reading the network name needs Location authorization on
    /// macOS 14 and later, and a system monitor should not make the user grant
    /// location access to see its signal strength. Everything here is
    /// available without any prompt.
    public struct WiFiInfo: Sendable, Codable, Equatable {
        public let interfaceName: String
        /// Received signal strength in dBm; around −50 is excellent, −80 poor.
        public let rssi: Int
        /// Noise floor in dBm. Signal minus noise is the margin that decides
        /// whether a strong-looking signal is actually usable.
        public let noise: Int
        public let transmitRateMbps: Double
        public let channel: Int
        public let band: Band

        public enum Band: String, Sendable, Codable {
            case ghz2_4 = "2.4 GHz"
            case ghz5 = "5 GHz"
            case ghz6 = "6 GHz"
            case unknown
        }
    }
}
