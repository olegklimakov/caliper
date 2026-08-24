import Foundation

/// Mounted volumes and their free space.
///
/// `getmntinfo` would also list the half-dozen internal volumes macOS keeps
/// mounted (VM, Preboot, xART, …), which nobody wants in a disk panel.
/// `mountedVolumeURLs` with `.skipHiddenVolumes` returns the volumes Finder
/// shows, which is the same list the user has in mind.
///
/// Stateless, and comparatively expensive — a resource-value read per volume —
/// which is why the cadence table samples it in tens of seconds.
struct VolumeSampler {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]

    func sample() -> [VolumeSample] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Self.keys,
                options: [.skipHiddenVolumes]
            ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                let total = values.volumeTotalCapacity,
                let available = values.volumeAvailableCapacityForImportantUsage
            else { return nil }

            return VolumeSample(
                name: values.volumeName ?? url.lastPathComponent,
                mountPoint: url.path,
                totalCapacity: UInt64(max(0, total)),
                availableCapacity: UInt64(max(0, available))
            )
        }
    }
}
