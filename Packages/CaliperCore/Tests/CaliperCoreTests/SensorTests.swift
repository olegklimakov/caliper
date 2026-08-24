import Testing

@testable import CaliperCore

@Test func classifiesTheSensorsThisGenerationReports() {
    #expect(SensorClassifier.group(key: "TN0n", name: "NAND CH0 temp") == .drive)
    #expect(SensorClassifier.group(key: "TG0C", name: "gas gauge battery") == .battery)
    #expect(SensorClassifier.group(key: "TP1b", name: "PMU tdie1") == .socDie)
    #expect(SensorClassifier.group(key: "TPel", name: "PMU tdie14") == .socDie)
}

@Test func keepsTheCalibrationReferenceOutOfTheTemperatures() {
    // "PMU tcal" reads about 52 °C while every real sensor on the same machine
    // reads about 31 °C; treating it as a die temperature would put twenty
    // phantom degrees in the menu bar.
    #expect(SensorClassifier.group(key: "TP0Z", name: "PMU tcal") == .calibration)
}

@Test func classifiesEarlierAppleSiliconNames() {
    #expect(SensorClassifier.group(key: "Tp01", name: "pACC MTR Temp Sensor1") == .cpuPerformance)
    #expect(SensorClassifier.group(key: "Te05", name: "eACC MTR Temp Sensor1") == .cpuEfficiency)
    #expect(SensorClassifier.group(key: "Tg0f", name: "GPU MTR Temp Sensor1") == .gpu)
}

@Test func refusesToGuessCoreTypeFromAnUnlabelledSensor() {
    let unlabelled = SensorClassifier.group(key: "TP7b", name: "PMU tdie7")
    #expect(unlabelled == .socDie)
    #expect(SensorClassifier.group(key: "ZZZZ", name: "something new") == .other)
}
