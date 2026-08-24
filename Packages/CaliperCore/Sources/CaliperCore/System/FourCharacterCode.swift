/// The four-character codes Apple's sensor interfaces are keyed by.
///
/// The SMC names every key this way (`FNum`, `TN0n`), and the HID event system
/// reports the same code packed into `LocationID`, so both samplers pack and
/// unpack it. Doing that by hand in each place is how the two drift apart.
enum FourCharacterCode {
    /// `"FNum"` → `0x464E756D`, or `nil` when the key is not four characters.
    static func packed(_ code: String) -> UInt32? {
        let bytes = Array(code.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// The inverse, rejecting anything that is not printable text — an
    /// identifier full of control characters is not a key we understand.
    static func unpacked(_ packed: UInt32) -> String? {
        guard packed != 0 else { return nil }
        let bytes = (0..<4).map { UInt8((packed >> (24 - 8 * $0)) & 0xff) }
        guard bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
