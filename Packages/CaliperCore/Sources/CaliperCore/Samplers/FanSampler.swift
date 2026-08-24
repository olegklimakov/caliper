/// Fan speeds from the SMC.
///
/// Probes once: a machine that reports no SMC, or reports zero fans, has no fan
/// feature at all and `isAvailable` stays false for the life of the process.
/// Every Mac laptop since the fanless Air ships one of each kind, so both cases
/// are real.
struct FanSampler {
    private let smc: SMCConnection?
    private let fanCount: Int

    var isAvailable: Bool { fanCount > 0 }

    init() {
        let smc = SMCConnection()
        self.smc = smc
        self.fanCount = smc?.value(forKey: "FNum").map { Int($0) } ?? 0
    }

    func sample() -> [FanReading] {
        guard let smc, fanCount > 0 else { return [] }

        return (0..<fanCount).compactMap { index in
            // The current speed is the one reading that must exist; a fan whose
            // limits are unreadable still has a speed worth showing.
            guard let rpm = smc.value(forKey: "F\(index)Ac") else { return nil }
            return FanReading(
                index: index,
                rpm: rpm,
                minimumRPM: smc.value(forKey: "F\(index)Mn"),
                maximumRPM: smc.value(forKey: "F\(index)Mx"),
                targetRPM: smc.value(forKey: "F\(index)Tg")
            )
        }
    }
}
