import CDriveHealth

/// NVMe SMART health of the internal drive.
///
/// Best-effort by design: plenty of Macs answer "unsupported" here, and the
/// panel simply omits the section rather than showing zeros. Probed once at
/// launch so a machine without it costs nothing per tick.
struct DriveHealthSampler {
    /// Probed once. The coordinator checks this before scheduling a read, so a
    /// machine without SMART never pays for the most expensive call in the app.
    let isAvailable: Bool

    init() {
        var data = NVMeSMARTData()
        isAvailable = CaliperReadNVMeSMART(&data)
    }

    func sample() -> DriveHealth? {
        guard isAvailable else { return nil }

        var data = NVMeSMARTData()
        guard CaliperReadNVMeSMART(&data) else { return nil }

        return DriveHealth(
            // The log reports whole kelvin; a drive answering zero is not at
            // absolute zero, it is declining to say — but its wear figures are
            // still worth reporting.
            celsius: data.TEMPERATURE > 0 ? Double(data.TEMPERATURE) - 273.15 : nil,
            lifeUsed: Double(data.PERCENTAGE_USED) / 100,
            availableSpare: Double(data.AVAILABLE_SPARE) / 100,
            availableSpareThreshold: Double(data.AVAILABLE_SPARE_THRESHOLD) / 100,
            powerOnHours: data.POWER_ON_HOURS.0,
            powerCycles: data.POWER_CYCLES.0,
            unsafeShutdowns: data.UNSAFE_SHUTDOWNS.0,
            mediaErrors: data.MEDIA_ERRORS.0,
            hasCriticalWarning: data.CRITICAL_WARNING != 0
        )
    }
}
