import Foundation

/// Read and write throughput of the physical storage devices.
///
/// The IORegistry lists a block storage driver for every mounted disk image as
/// well, and on a developer's Mac those outnumber the real disks. They are
/// filtered out by their interconnect location: a device backed by a file is
/// not a device whose throughput belongs in a disk chart.
struct DiskActivitySampler {
    private var previous: [UInt64: Counters] = [:]
    private var window = RateWindow()
    /// Device identity by registry entry, resolved once: deciding whether a
    /// driver is a real disk walks to its parent and reads two property
    /// dictionaries, and the answer cannot change while it stays plugged in.
    /// `nil` records "not a real device", so a disk image is rejected once.
    private var deviceNames: [UInt64: String?] = [:]

    private struct Counters {
        let name: String
        let read: UInt64
        let written: UInt64
    }

    mutating func sample(at instant: ContinuousClock.Instant) -> DiskActivitySample? {
        let current = readDevices()
        guard !current.isEmpty else { return nil }
        defer { previous = current }
        guard let seconds = window.advance(to: instant) else { return nil }

        var devices: [DiskActivitySample.Device] = []
        devices.reserveCapacity(current.count)
        var totalRead = 0.0
        var totalWrite = 0.0

        for (id, counters) in current.sorted(by: { $0.key < $1.key }) {
            let before = previous[id]
            let readRate = Double(counters.read.subtractingClamped(before?.read ?? counters.read)) / seconds
            let writeRate =
                Double(counters.written.subtractingClamped(before?.written ?? counters.written)) / seconds

            devices.append(
                DiskActivitySample.Device(
                    name: counters.name,
                    readRate: readRate,
                    writeRate: writeRate,
                    bytesRead: counters.read,
                    bytesWritten: counters.written
                )
            )
            totalRead += readRate
            totalWrite += writeRate
        }

        return DiskActivitySample(devices: devices, readRate: totalRead, writeRate: totalWrite)
    }

    mutating func resetBaseline() {
        previous = [:]
        window.reset()
        // Devices may have come or gone while the machine slept.
        deviceNames.removeAll()
    }

    private mutating func readDevices() -> [UInt64: Counters] {
        var devices: [UInt64: Counters] = [:]
        // Named or not: a file-backed device has no product name and never
        // reaches `devices`, and those are the entries the cache has to keep.
        var present: Set<UInt64> = []

        IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let id = IORegistry.entryID(driver),
                let statistics = IORegistry.dictionary(driver, "Statistics"),
                let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
                let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value
            else { return }

            present.insert(id)

            let name: String?
            if let cached = deviceNames[id] {
                name = cached
            } else {
                name = IORegistry.withParent(driver, physicalDeviceName)
                deviceNames[id] = name
            }
            guard let name else { return }

            devices[id] = Counters(name: name, read: read, written: written)
        }
        // Forget devices that are gone — every mounted disk image adds an
        // entry. Against what this sweep saw, not against `devices`: a
        // file-backed device is cached as a `nil` name and never reaches
        // `devices`, so filtering on that keeps every image ever mounted.
        deviceNames = deviceNames.filter { present.contains($0.key) }
        return devices
    }

    /// Product name of a real device, or `nil` for anything backed by a file.
    private func physicalDeviceName(of device: io_registry_entry_t) -> String? {
        let characteristics = IORegistry.dictionary(device, "Protocol Characteristics")
        guard characteristics?["Physical Interconnect Location"] as? String != "File" else {
            return nil
        }
        return IORegistry.dictionary(device, "Device Characteristics")?["Product Name"] as? String
            ?? "Disk"
    }
}
