import CPrivateShims
import Foundation

/// On-board temperatures, through the HID event system.
///
/// The sensor list is enumerated once at launch. The system reports the same
/// physical sensor through several service clients — 77 of them for 27 sensors
/// on this machine — so they are collapsed by their `LocationID`, which is the
/// sensor's four-character key. Reading only one client per sensor is the
/// difference between 27 and 77 cross-process calls on every tick.
///
/// A sensor that is present but not wired up reports around −9200 °C, so
/// readings are sanity-checked on the way out rather than trusted.
struct TemperatureSampler {
    /// The event system client and its service array own the service clients.
    /// Holding a bare reference to an element instead leaves a dangling pointer
    /// the moment the array is released, which crashes on the next read.
    private let client: IOHIDEventSystemClient?
    private let services: CFArray?
    private let sensors: [Sensor]

    private struct Sensor {
        let key: String
        let name: String
        let group: SensorGroup
        /// Index into `services`, not a reference to the element.
        let index: CFIndex
    }

    /// A machine that reports no sensors hides the whole feature.
    var isAvailable: Bool { !sensors.isEmpty }

    /// Physically plausible range for anything inside a Mac.
    private static let plausible = -40.0...150.0

    init() {
        guard SensorPolicy.allowsPrivateInterfaces,
            let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        else {
            self.client = nil
            self.services = nil
            self.sensors = []
            return
        }

        let matching =
            [
                kCaliperHIDPrimaryUsagePageKey: kCaliperHIDPageAppleVendor,
                kCaliperHIDPrimaryUsageKey: kCaliperHIDUsageTemperature,
            ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)

        self.client = client
        self.services = IOHIDEventSystemClientCopyServices(client)
        self.sensors = Self.describe(self.services)
    }

    func sample() -> [TemperatureReading] {
        guard let services else { return [] }

        return sensors.compactMap { sensor in
            guard let service = Self.service(in: services, at: sensor.index),
                let event = IOHIDServiceClientCopyEvent(
                    service,
                    kCaliperHIDEventTypeTemperature,
                    0,
                    0
                )
            else { return nil }

            let celsius = IOHIDEventGetFloatValue(
                event,
                CaliperHIDEventFieldBase(kCaliperHIDEventTypeTemperature)
            )
            guard Self.plausible.contains(celsius) else { return nil }

            return TemperatureReading(
                key: sensor.key,
                name: sensor.name,
                group: sensor.group,
                celsius: celsius
            )
        }
    }

    private static func describe(_ services: CFArray?) -> [Sensor] {
        guard let services else { return [] }

        var sensors: [String: Sensor] = [:]
        for index in 0..<CFArrayGetCount(services) {
            guard let service = service(in: services, at: index),
                let key = keyOfSensor(service),
                sensors[key] == nil
            else { continue }

            let name = IOHIDServiceClientCopyProperty(service, kCaliperHIDProductKey) as? String
            let label = name ?? key
            sensors[key] = Sensor(
                key: key,
                name: label,
                group: SensorClassifier.group(key: key, name: label),
                index: index
            )
        }
        return sensors.values.sorted { $0.key < $1.key }
    }

    private static func service(in services: CFArray, at index: CFIndex) -> IOHIDServiceClient? {
        guard let raw = CFArrayGetValueAtIndex(services, index) else { return nil }
        return Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
    }

    /// `LocationID` holds the sensor's four-character key packed into an
    /// integer — the same `TN0n` or `TP1b` the SMC uses.
    private static func keyOfSensor(_ service: IOHIDServiceClient) -> String? {
        guard
            let number = IOHIDServiceClientCopyProperty(service, kCaliperHIDLocationIDKey)
                as? NSNumber
        else { return nil }

        return FourCharacterCode.unpacked(number.uint32Value)
    }
}
