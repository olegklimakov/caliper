import Testing

@testable import CaliperCore

@Test func leavesSeriesThatAlreadyFitAlone() {
    #expect(Downsample.peaks(of: [1.0, 2, 3], to: 10) == [1, 2, 3])
    #expect(Downsample.peaks(of: [1.0, 2, 3], to: 3) == [1, 2, 3])
    #expect(Downsample.peaks(of: [Double](), to: 5).isEmpty)
}

@Test func keepsThePeakOfEachBucket() {
    // Six samples into three points: the maximum of each pair survives.
    #expect(Downsample.peaks(of: [1.0, 5, 2, 2, 3, 4], to: 3) == [5, 2, 4])
}

@Test func neverDropsOrRepeatsSamples() {
    // Ten into four does not divide evenly; the buckets must still tile the
    // whole input, so the last one has to reach the final sample.
    let values = (1...10).map(Double.init)
    let reduced = Downsample.peaks(of: values, to: 4)

    #expect(reduced.count == 4)
    #expect(reduced.last == 10)
    #expect(reduced == [2, 5, 7, 10])
}

@Test func aSpikeSurvivesReduction() {
    // The whole point: averaging would bury this at 0.1, and a monitor that
    // hides spikes is not doing its job.
    var values = [Double](repeating: 0, count: 300)
    values[150] = 1.0

    #expect(Downsample.peaks(of: values, to: 28).max() == 1.0)
}

@Test func refusesNonsensicalWidths() {
    #expect(Downsample.peaks(of: [1.0, 2, 3], to: 0).isEmpty)
    #expect(Downsample.peaks(of: [1.0, 2, 3], to: -5).isEmpty)
}

@Test func reducesARingBufferWithoutCopyingItFirst() {
    var buffer = RingBuffer<Double>(capacity: 100)
    for value in 1...100 {
        buffer.append(Double(value))
    }

    let reduced = Downsample.peaks(of: buffer, to: 10)
    #expect(reduced.count == 10)
    #expect(reduced.first == 10)
    #expect(reduced.last == 100)
}
