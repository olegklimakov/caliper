import CaliperCore
import Observation

/// The newest snapshot plus the recent history every surface draws from.
///
/// One store for the menu bar and the panels: they show the same numbers, and
/// keeping two would guarantee they disagree by a tick. History is a
/// fixed-capacity ring per series, so a Mac left running for a week costs what
/// it costs after five minutes.
///
/// This is the live window only. Phase 3's store answers for hours and days;
/// these buffers answer for the last few minutes, which is what a popover and a
/// menu bar sparkline actually show.
@MainActor
@Observable
final class LiveMetrics {
    /// Five minutes of one-second samples.
    private static let capacity = 300

    private(set) var snapshot: SystemSnapshot?

    private(set) var cpuTotal = RingBuffer<Double>(capacity: capacity)
    private(set) var cpuClusters: [RingBuffer<Double>] = []
    private(set) var memoryUsed = RingBuffer<Double>(capacity: capacity)
    private(set) var download = RingBuffer<Double>(capacity: capacity)
    private(set) var upload = RingBuffer<Double>(capacity: capacity)
    private(set) var diskRead = RingBuffer<Double>(capacity: capacity)
    private(set) var diskWrite = RingBuffer<Double>(capacity: capacity)
    private(set) var peakTemperature = RingBuffer<Double>(capacity: capacity)

    func update(with snapshot: SystemSnapshot) {
        self.snapshot = snapshot

        if let cpu = snapshot.cpu {
            cpuTotal.append(cpu.total)
            if cpuClusters.count != cpu.clusters.count {
                cpuClusters = cpu.clusters.map { _ in RingBuffer<Double>(capacity: Self.capacity) }
            }
            for (index, value) in cpu.clusters.enumerated() {
                cpuClusters[index].append(value)
            }
        }
        if let memory = snapshot.memory, memory.total > 0 {
            memoryUsed.append(memory.usedFraction)
        }
        if let network = snapshot.network {
            download.append(network.downloadRate)
            upload.append(network.uploadRate)
        }
        if let disk = snapshot.diskActivity {
            diskRead.append(disk.readRate)
            diskWrite.append(disk.writeRate)
        }
        if let peak = currentPeakTemperature {
            peakTemperature.append(peak)
        }
    }

    var currentPeakTemperature: Double? { snapshot?.sensors?.peakTemperature }
}
