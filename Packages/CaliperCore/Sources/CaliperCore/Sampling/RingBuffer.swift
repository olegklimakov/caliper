/// Fixed-capacity buffer holding the most recent `capacity` elements.
///
/// Storage is allocated once and never grows: `append` overwrites the oldest
/// element, so a sampler running for days costs the same as one running for a
/// minute. Indexing is oldest-first, the order charts draw in.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    /// Where the next element is written, i.e. also the oldest element once full.
    private var nextIndex: Int
    public private(set) var count: Int

    public var capacity: Int { storage.count }
    public var isFull: Bool { count == storage.count }

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer requires a positive capacity")
        storage = Array(repeating: nil, count: capacity)
        nextIndex = 0
        count = 0
    }

    public mutating func append(_ element: Element) {
        storage[nextIndex] = element
        nextIndex = (nextIndex + 1) % storage.count
        if count < storage.count {
            count += 1
        }
    }
}

extension RingBuffer: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> Element {
        precondition(position >= 0 && position < count, "RingBuffer index out of range")
        let oldest = isFull ? nextIndex : 0
        return storage[(oldest + position) % storage.count]!
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
