import Darwin

/// Per-interface traffic from the routing socket's interface list.
///
/// The kernel hands back a variable-length message stream, so the read buffer
/// is kept between ticks and only grows — sampling once a second must not mean
/// allocating once a second.
///
/// `if_data64.ifi_ibytes` is only fully populated for Apple platform binaries;
/// every third-party process reads the low 32 bits with a zeroed high word,
/// whatever its signature or deployment target. That is why only rates leave
/// this sampler: a wrap at four gigabytes is clamped to a single lost interval,
/// which needs sustained multi-gigabyte-per-second traffic to even occur.
struct NetworkSampler {
    private var buffer: [UInt8] = []
    private var previous: [String: Counters] = [:]
    private var window = RateWindow()

    private struct Counters {
        let received: UInt64
        let sent: UInt64
        let isLoopback: Bool
    }

    mutating func sample(at instant: ContinuousClock.Instant) -> NetworkSample? {
        guard let current = readInterfaces() else { return nil }
        defer { previous = current }
        guard let seconds = window.advance(to: instant) else { return nil }

        var interfaces: [NetworkSample.Interface] = []
        interfaces.reserveCapacity(current.count)
        var totalDownload = 0.0
        var totalUpload = 0.0

        for (name, counters) in current.sorted(by: { $0.key < $1.key }) {
            // An interface that appeared since the last tick has no baseline;
            // its first interval is reported as idle rather than as a burst.
            let before = previous[name]
            let download =
                Double(counters.received.subtractingClamped(before?.received ?? counters.received))
                / seconds
            let upload =
                Double(counters.sent.subtractingClamped(before?.sent ?? counters.sent)) / seconds

            interfaces.append(
                NetworkSample.Interface(
                    name: name,
                    isLoopback: counters.isLoopback,
                    downloadRate: download,
                    uploadRate: upload
                )
            )
            if !counters.isLoopback {
                totalDownload += download
                totalUpload += upload
            }
        }

        return NetworkSample(
            interfaces: interfaces,
            downloadRate: totalDownload,
            uploadRate: totalUpload
        )
    }

    mutating func resetBaseline() {
        previous = [:]
        window.reset()
    }

    private mutating func readInterfaces() -> [String: Counters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        var needed = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else {
            return nil
        }
        if buffer.count < needed {
            buffer = [UInt8](repeating: 0, count: needed)
        }

        var length = buffer.count
        let read = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &length, nil, 0)
        }
        guard read == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> [String: Counters] in
            var interfaces: [String: Counters] = [:]
            var offset = 0

            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard header.ifm_type == RTM_IFINFO2,
                    offset + MemoryLayout<if_msghdr2>.size <= length
                else { continue }

                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard
                    let name = Self.interfaceName(
                        in: raw,
                        at: offset + MemoryLayout<if_msghdr2>.size,
                        limit: length
                    )
                else { continue }

                interfaces[name] = Counters(
                    received: info.ifm_data.ifi_ibytes,
                    sent: info.ifm_data.ifi_obytes,
                    isLoopback: info.ifm_flags & IFF_LOOPBACK != 0
                )
            }
            return interfaces
        }
    }

    /// The interface name lives in the `sockaddr_dl` that follows each message.
    private static func interfaceName(
        in raw: UnsafeRawBufferPointer,
        at offset: Int,
        limit: Int
    ) -> String? {
        guard offset + MemoryLayout<sockaddr_dl>.size <= limit else { return nil }
        let address = raw.loadUnaligned(fromByteOffset: offset, as: sockaddr_dl.self)

        let nameLength = Int(address.sdl_nlen)
        guard nameLength > 0,
            let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data),
            offset + dataOffset + nameLength <= limit
        else { return nil }

        let start = offset + dataOffset
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<start + nameLength]), as: UTF8.self)
    }
}
