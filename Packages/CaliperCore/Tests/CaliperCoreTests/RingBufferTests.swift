import Testing

@testable import CaliperCore

@Test func fillsUpBeforeWrappingAround() {
    var buffer = RingBuffer<Int>(capacity: 3)
    #expect(buffer.isEmpty)

    buffer.append(1)
    buffer.append(2)

    #expect(Array(buffer) == [1, 2])
    #expect(buffer.count == 2)
    #expect(buffer.isFull == false)
}

@Test func overwritesOldestOnceFull() {
    var buffer = RingBuffer<Int>(capacity: 3)
    for value in 1...5 {
        buffer.append(value)
    }

    #expect(Array(buffer) == [3, 4, 5])
    #expect(buffer.count == 3)
    #expect(buffer.capacity == 3)
    #expect(buffer.first == 3)
    #expect(buffer.last == 5)
}

@Test func wrapsRepeatedlyWithoutDrift() {
    var buffer = RingBuffer<Int>(capacity: 4)
    for value in 1...100 {
        buffer.append(value)
    }

    #expect(Array(buffer) == [97, 98, 99, 100])
}

@Test func aSingleSlotAlwaysHoldsTheNewestElement() {
    var buffer = RingBuffer<String>(capacity: 1)
    buffer.append("old")
    buffer.append("new")

    #expect(Array(buffer) == ["new"])
    #expect(buffer.count == 1)
}
