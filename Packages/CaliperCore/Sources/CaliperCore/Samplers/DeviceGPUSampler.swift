import Foundation
import IOKit

/// What the accelerator is doing, from its own `PerformanceStatistics`.
///
/// The node rather than its user clients, which is what makes this the cheap
/// half of the GPU story: **0.038 ms a read**, against the 1.14 ms
/// `GPUProcessSampler` pays to walk every client — thirty times less. That is
/// why the two are separate metrics on separate cadences: the per-process
/// sweep runs at drive-health rarity off screen, and this one is cheap enough
/// to fold into history every second.
///
/// Public IOKit, undocumented properties. The first Mac whose accelerator
/// names them differently loses this reading, not the app — the same rule
/// `GPUProcessSampler` follows.
struct DeviceGPUSampler {
    /// Probed once by doing the read, so the coordinator can stop asking.
    let isAvailable: Bool

    init() {
        guard GPUPolicy.allowsAcceleratorSweep else {
            isAvailable = false
            return
        }
        isAvailable = Self.read(at: Date()) != nil
    }

    func sample() -> GPUDeviceSample? {
        guard isAvailable else { return nil }
        return Self.read(at: Date())
    }

    /// The first accelerator that reports statistics. One rather than a sum:
    /// on a machine with two GPUs, "44 %" of an unnamed average is a number
    /// about nothing, and picking the one Metal is using is a bigger question
    /// than this reading is worth.
    private static func read(at moment: Date) -> GPUDeviceSample? {
        var found: GPUDeviceSample?
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            guard found == nil,
                let statistics = IORegistry.property(accelerator, "PerformanceStatistics")
                    as? [String: Any],
                let device = statistics["Device Utilization %"] as? Int
            else { return }

            func percent(_ key: String) -> Double {
                Double(statistics[key] as? Int ?? 0) / 100
            }
            func bytes(_ key: String) -> UInt64 {
                (statistics[key] as? NSNumber)?.uint64Value ?? 0
            }

            found = GPUDeviceSample(
                sampledAt: moment,
                utilisation: Double(device) / 100,
                rendererUtilisation: percent("Renderer Utilization %"),
                tilerUtilisation: percent("Tiler Utilization %"),
                memoryInUse: bytes("In use system memory"),
                memoryAllocated: bytes("Alloc system memory"),
                coreCount: coreCount(of: accelerator),
                recoveryCount: statistics["recoveryCount"] as? Int ?? 0
            )
        }
        return found
    }

    /// `num_cores` out of the accelerator's configuration — 20 on this
    /// machine, which is what lets a readout say "20-core GPU" rather than
    /// asking the user to know.
    private static func coreCount(of accelerator: io_registry_entry_t) -> Int? {
        guard
            let configuration = IORegistry.property(accelerator, "GPUConfigurationVariable")
                as? [String: Any]
        else { return nil }
        return configuration["num_cores"] as? Int
    }
}
