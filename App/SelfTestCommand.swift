import Foundation
import CaliperCore

/// Prints one `SystemSnapshot` as JSON and exits.
///
/// It waits for the *second* tick of the real coordinator: every rate in the
/// snapshot is the difference between two readings of a kernel counter, so the
/// first tick only seeds baselines. Driving the actual timer rather than
/// sampling by hand means this also proves the sampling loop runs.
enum SelfTestCommand {
    static let flag = "--selftest"
    /// Two one-second ticks plus slack; a miss means the timer never fired,
    /// which should fail the run rather than hang it.
    private static let deadline = Duration.seconds(10)

    static func run() async -> Never {
        let coordinator = SamplingCoordinator(activityLevel: .dashboardOpen)
        // Subscribe before starting, or the first tick can land before anyone
        // is listening and the reading is taken over the wrong interval.
        let snapshots = await coordinator.snapshots()
        await coordinator.start()

        guard let snapshot = await sampleWithDeadline(snapshots) else {
            fail("no snapshot within \(deadline)")
        }
        await coordinator.stop()

        do {
            print(try snapshot.jsonRepresentation())
            exit(EXIT_SUCCESS)
        } catch {
            fail("could not encode snapshot: \(error)")
        }
    }

    private static func sampleWithDeadline(
        _ snapshots: AsyncStream<SystemSnapshot>
    ) async -> SystemSnapshot? {
        await withTaskGroup(of: SystemSnapshot?.self) { group in
            group.addTask {
                var ticks = 0
                for await snapshot in snapshots {
                    ticks += 1
                    if ticks == 2 { return snapshot }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Caliper: selftest failed: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
