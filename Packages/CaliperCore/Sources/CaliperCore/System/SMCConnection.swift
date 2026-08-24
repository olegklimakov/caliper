import CPrivateShims
import Foundation
import IOKit

/// Read-only connection to the System Management Controller.
///
/// Caliper never writes to the SMC — fan control is an explicit non-goal, and a
/// bug in a monitor should not be able to change how the machine cools itself.
/// Only the read command is implemented, so there is no write path to get wrong.
///
/// Returns `nil` from `init` when the SMC cannot be opened, which is how the
/// fan feature disappears on a machine that does not have one.
final class SMCConnection {
    private let connection: io_connect_t

    init?() {
        guard SensorPolicy.allowsPrivateInterfaces else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Reads a four-character key and converts it to a number, whatever fixed
    /// point or float the SMC happens to store it in.
    func value(forKey key: String) -> Double? {
        guard let code = FourCharacterCode.packed(key), let reading = read(code) else { return nil }
        return Self.decode(reading)
    }

    // MARK: - Wire protocol

    private struct Reading {
        let type: UInt32
        let size: Int
        let bytes: [UInt8]
    }

    private func read(_ key: UInt32) -> Reading? {
        var info = CaliperSMCParamStruct()
        info.key = key
        info.data8 = UInt8(kCaliperSMCCmdReadKeyInfo)
        guard let described = call(info), described.keyInfo.dataSize > 0 else { return nil }

        var request = CaliperSMCParamStruct()
        request.key = key
        request.data8 = UInt8(kCaliperSMCCmdReadBytes)
        request.keyInfo = described.keyInfo
        guard let output = call(request) else { return nil }

        let size = min(Int(described.keyInfo.dataSize), MemoryLayout.size(ofValue: output.bytes))
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return Reading(type: described.keyInfo.dataType, size: size, bytes: bytes)
    }

    private func call(_ input: CaliperSMCParamStruct) -> CaliperSMCParamStruct? {
        var input = input
        var output = CaliperSMCParamStruct()
        var outputSize = MemoryLayout<CaliperSMCParamStruct>.size

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(kCaliperSMCHandleYPCEvent),
            &input,
            MemoryLayout<CaliperSMCParamStruct>.size,
            &output,
            &outputSize
        )
        return result == kIOReturnSuccess ? output : nil
    }

    private static func decode(_ reading: Reading) -> Double? {
        guard let type = FourCharacterCode.unpacked(reading.type) else { return nil }
        return decode(type: type, bytes: reading.bytes)
    }

    /// SMC values are tagged with a four-character type. Apple Silicon uses
    /// `flt` and `ui8`; the fixed-point types are what Intel Macs report, and
    /// an unrecognised tag yields `nil` rather than a misread number.
    ///
    /// Split from the connection so the encodings can be tested on any machine,
    /// not just one that happens to have a sensor of each type.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "ui8 ":
            return bytes.count >= 1 ? Double(bytes[0]) : nil
        case "ui16":
            return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32":
            return bytes.count >= 4
                ? Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) : nil
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let pattern = bytes.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Float(bitPattern: pattern))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 6 | UInt16(bytes[1] >> 2))
        case "ioft":
            guard bytes.count >= 8 else { return nil }
            let raw = bytes.prefix(8).reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return Double(raw) / 65536
        default:
            return nil
        }
    }

}
