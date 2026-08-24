/// Decides what a temperature sensor is attached to.
///
/// Apple names these sensors for its own convenience and the naming changes
/// between chip generations: an M1 reports "pACC MTR Temp Sensor1" and
/// "GPU MTR Temp Sensor2", while an M5 Pro reports fourteen sensors called
/// "PMU tdie1" through "PMU tdie14" and nothing else. So this table recognises
/// what it can and says `socDie` — not `cpuPerformance` — for the rest. A
/// monitor that invents a label is worse than one that admits the machine did
/// not say.
enum SensorClassifier {
    static func group(key: String, name: String) -> SensorGroup {
        let name = name.lowercased()

        // Named blocks, when the chip generation bothers to name them.
        if name.contains("pacc") { return .cpuPerformance }
        if name.contains("eacc") { return .cpuEfficiency }
        if name.contains("gpu") { return .gpu }

        // A calibration reference reads far hotter than any real sensor, so it
        // must never be mistaken for one.
        if name.contains("tcal") || key == "TP0Z" { return .calibration }

        if name.contains("nand") || name.contains("ssd") || key.hasPrefix("TN") {
            return .drive
        }
        if name.contains("battery") || name.contains("gas gauge") || key.hasPrefix("TG") {
            return .battery
        }
        if key.hasPrefix("TP") || name.contains("tdie") || name.contains("soc") {
            return .socDie
        }
        return .other
    }
}
