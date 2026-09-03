import AppKit
import CaliperCore
import CaliperHistory

/// Writes every menu bar indicator, panel and the dashboard pane to PNGs, drawn
/// from real samples.
///
/// The menu bar cannot be inspected from a test: no view hierarchy to query, and
/// no window to screenshot without a screen recording entitlement. Rendering the
/// same images to disk is how it gets checked against the mockups.
enum UIPreview {
    static let flag = "--preview-ui"

    static func run(writingTo directory: String) async -> Never {
        let coordinator = SamplingCoordinator(demand: .everything)
        let snapshots = await coordinator.snapshots()
        await coordinator.start()

        // Enough for the sparklines to have a shape: one sample draws nothing
        // and two draw a straight line.
        let state = await MainActor.run { LiveMetrics() }
        var ticks = 0
        for await snapshot in snapshots {
            await MainActor.run { state.update(with: snapshot) }
            ticks += 1
            if ticks >= 20 { break }
        }
        await coordinator.stop()

        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let history = await previewHistory()

        for appearance in ["dark", "light"] {
            let theme = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)!
            await MainActor.run {
                theme.performAsCurrentDrawingAppearance {
                    for module in MenuBarModule.allCases {
                        guard let image = PanelPreview.render(module, metrics: state, appearance: theme)
                        else { continue }
                        write(
                            image,
                            to: url.appendingPathComponent("panel-\(module.rawValue)-\(appearance).png"),
                            scale: 1,
                            background: nil
                        )
                    }

                    if let drilled = PanelPreview.renderDrilled(.cpu, metrics: state, appearance: theme) {
                        write(
                            drilled,
                            to: url.appendingPathComponent("panel-drilled-\(appearance).png"),
                            scale: 1,
                            background: nil
                        )
                    }

                    if let combined = PanelPreview.renderCombined(
                        metrics: state,
                        preferences: previewPreferences,
                        appearance: theme
                    ) {
                        write(
                            combined,
                            to: url.appendingPathComponent("panel-combined-\(appearance).png"),
                            scale: 1,
                            background: nil
                        )
                    }

                    let loader = history.map { DashboardHistory(preloaded: $0.slice, consumers: $0.consumers) }
                    if let history, let loader,
                        let dashboard = PanelPreview.renderDashboard(
                            metrics: state,
                            history: loader,
                            cursor: history.cursor,
                            appearance: theme
                        )
                    {
                        write(
                            dashboard,
                            to: url.appendingPathComponent("dashboard-\(appearance).png"),
                            scale: 1,
                            background: nil
                        )
                    }
                    if let history, let loader,
                        let overview = PanelPreview.renderOverview(
                            metrics: state,
                            history: loader,
                            cursor: history.cursor,
                            appearance: theme
                        )
                    {
                        write(
                            overview,
                            to: url.appendingPathComponent("overview-\(appearance).png"),
                            scale: 1,
                            background: nil
                        )
                    }
                    for (state, search) in previewRegistry {
                        if let pane = PanelPreview.renderProcesses(
                            search: search.result,
                            query: search.query,
                            appearance: theme
                        ) {
                            write(
                                pane,
                                to: url.appendingPathComponent("processes-\(state)-\(appearance).png"),
                                scale: 1,
                                background: nil
                            )
                        }
                    }
                    for fate in CardFate.allCases {
                        let model = previewProcessCard(fate)
                        if let card = PanelPreview.renderProcessCard(
                            model: model,
                            // The real machine, sampled at the top of this
                            // run: the card's device context is a reading, and
                            // a literal would be the one number in the picture
                            // nobody had measured.
                            machine: state.snapshot,
                            appearance: theme
                        ) {
                            write(
                                card,
                                to: url.appendingPathComponent(
                                    "process-card-\(fate.rawValue)-\(appearance).png"
                                ),
                                scale: 1,
                                background: nil
                            )
                        }
                    }
                }
            }
        }

        for style in [IndicatorStyle(isTemplate: true), IndicatorStyle(isTemplate: false)] {
            let suffix = style.isTemplate ? "template" : "colour"
            for appearance in ["dark", "light"] {
                let theme = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)!
                await MainActor.run {
                    theme.performAsCurrentDrawingAppearance {
                        for module in MenuBarModule.allCases {
                            for variant in partVariants {
                                let image = module.indicator(parts: variant.parts)
                                    .makeImage(state, style: style)
                                let name =
                                    "\(module.rawValue)-\(variant.name)-\(suffix)-\(appearance).png"
                                write(image, to: url.appendingPathComponent(name))
                            }
                        }
                        // The only place the gaps between modules show.
                        let combined = CombinedStrip.image(
                            of: MenuBarParts().enabled.map { $0.indicator(parts: MenuBarParts()[$0]) },
                            state: state,
                            style: style
                        )
                        write(combined, to: url.appendingPathComponent("combined-\(suffix)-\(appearance).png"))
                        // The update dot over the busiest strip there is: it
                        // has to read as a separate mark rather than as one more
                        // thing a module drew.
                        write(
                            MenuBarBadge.over(combined, style: style),
                            to: url.appendingPathComponent("combined-badged-\(suffix)-\(appearance).png")
                        )
                        // And over the narrowest thing the strip can be, where
                        // the eight points it claims are most of the item.
                        write(
                            MenuBarBadge.over(MenuBarPlaceholder.image(style: style), style: style),
                            to: url.appendingPathComponent("placeholder-badged-\(suffix)-\(appearance).png")
                        )
                    }
                }
            }
        }

        report("wrote previews to \(directory)")
    }

    /// A day of plausible history in a throwaway store, and the moment worth
    /// parking the overview's cursor on.
    ///
    /// Synthetic rather than recorded: a dev machine that sat idle all night
    /// renders five flat lines that say nothing about the layout. The shape is a
    /// load burst with the temperature following a few buckets late — the
    /// correlation the pane exists to show.
    private static func previewHistory() async -> (slice: HistorySlice, cursor: Date, consumers: ProcessBucket?)? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("caliper-preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let store = try? HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        else { return nil }

        let span = HistorySpan.day.seconds
        let tier = HistoryStore.tier(forRange: span)
        let end = tier.bucketStart(of: Date())
        let buckets = Int(span) / tier.seconds
        let peak = Int(Double(buckets) * 0.66)

        var samples: [HistorySample] = []
        for index in 0..<buckets {
            let timestamp = end.addingTimeInterval(-Double((buckets - 1 - index) * tier.seconds))
            let phase = Double(index) / Double(buckets)
            let load = exp(-pow((phase - 0.66) * 11, 2))
            // Heat arrives late and leaves slowly.
            let heat = exp(-pow((phase - 0.71) * 9, 2))
            let ripple = 0.5 + 0.5 * sin(phase * 34)

            for (series, value) in [
                MetricSeries.cpu: 0.06 + 0.72 * load + 0.04 * ripple,
                .memory: 0.42 + 0.28 * phase + 0.03 * ripple,
                .temperature: 37 + 29 * heat + 1.5 * ripple,
                .networkDownload: 2e5 + 4.2e7 * load * ripple,
                .diskRead: 1e5 + 9e6 * load * ripple,
            ] {
                samples.append(
                    HistorySample(
                        series: series,
                        timestamp: timestamp,
                        aggregate: Aggregate(
                            minimum: value * 0.72,
                            average: value,
                            maximum: series == .cpu || series == .memory
                                ? Swift.min(value * 1.3, 1) : value * 1.4
                        )
                    )
                )
            }
        }

        let cursor = end.addingTimeInterval(-Double((buckets - 1 - peak) * tier.seconds))
        let reader = HistoryReader(store: store)

        guard (try? store.write(samples, tier: tier)) != nil,
            let slice = try? await reader.slice(MetricSeries.allCases, span: span)
        else { return nil }

        return (slice, cursor, await previewConsumers(store: store, reader: reader, at: cursor))
    }

    /// Fed through the real recorder rather than written as rows: the readout
    /// shows what the recorder chose to keep, and hand-built rows would preview
    /// a list this app never stores.
    private static func previewConsumers(
        store: HistoryStore,
        reader: HistoryReader,
        at cursor: Date
    ) async -> ProcessBucket? {
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        // The two rankings deliberately disagree — a browser holds gigabytes
        // at no CPU, a compiler the other way round. Ranking alike would show
        // two identical columns and prove nothing.
        // Watts are their own column because they are their own order: the
        // WebContent process draws more than the compiler above it on CPU.
        let load: [(String, Double, UInt64, Double)] = [
            ("Xcode", 3.4, 1_100_000_000, 2.1),
            ("swift-frontend", 2.1, 620_000_000, 1.6),
            ("com.apple.WebKit.WebContent", 0.7, 4_300_000_000, 1.9),
            ("Brave Browser Helper (Renderer)", 0.2, 2_600_000_000, 0.4),
            ("kernel_task", 0.4, 180_000_000, 0.2),
            ("WindowServer", 0.3, 410_000_000, 0.5),
            ("Telegram", 0.1, 830_000_000, 0.1),
        ]
        // Two sweeps in one bucket, so the stored numbers are a mean of more
        // than one reading.
        for offset in [0.0, 15.0] {
            recorder.record(
                ProcessesSample(
                    sampledAt: cursor.addingTimeInterval(offset),
                    interval: 15,
                    topByCPU: load.enumerated().map { index, entry in
                        ProcessSample(
                            pid: Int32(index + 1),
                            name: entry.0,
                            cpu: entry.1 * (offset == 0 ? 1.1 : 0.9),
                            memoryFootprint: entry.2,
                            diskRate: 0,
                            power: entry.3,
                            wakeupsPerSecond: 0,
                            performanceCycleShare: nil,
                            qos: nil
                        )
                    },
                    topByMemory: [],
                    topByDisk: [],
                    topByPower: [],
                    watched: [],
                    roster: load.map { ProcessIdentity(name: $0.0, path: nil) },
                    unreadableCount: 0
                )
            )
        }
        guard (try? recorder.flushNow()) != nil else { return nil }
        return try? await reader.consumers(at: cursor, retention: .week)
    }

    /// The search room in its two states worth checking: a query with matches,
    /// and a query with none — which has to say how much *is* recorded, or
    /// "not found" reads as "never ran".
    ///
    /// The switched-off and unavailable states are one `note` each with the
    /// same shape as the empty one, which this already draws.
    @MainActor
    private static var previewRegistry: [(String, (query: String, result: ProcessNameSearch))] {
        // Relative to the real clock, unlike the card's fixed fixture: the three
        // widths `RegistryDate` prints are chosen by age, and a frozen date
        // would only ever exercise one of them.
        let now = Date()
        func seen(
            _ name: String,
            _ path: String?,
            last: TimeInterval,
            first: TimeInterval
        ) -> ProcessAppearance {
            ProcessAppearance(
                name: name,
                path: path,
                firstSeen: now.addingTimeInterval(-first),
                lastSeen: now.addingTimeInterval(-last)
            )
        }
        let matches = [
            seen("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", last: 600, first: 9 * 86_400),
            seen("Google Chrome Helper (Renderer)", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/141.0.7390.55/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", last: 600, first: 9 * 86_400),
            // The room's whole reason: a name that ran once in the night, ranks
            // nowhere, and is not on the machine any more.
            seen("chromedriver", "/opt/homebrew/bin/chromedriver", last: 4 * 86_400 + 3_600, first: 4 * 86_400 + 5_400),
            seen("chrome_crashpad_handler", nil, last: 5 * 86_400, first: 9 * 86_400),
        ]
        return [
            ("found", ("chrom", ProcessNameSearch(matches: matches, matched: 12, recorded: 611))),
            ("empty", ("figma", ProcessNameSearch(matches: [], matched: 0, recorded: 611))),
        ]
    }

    /// A day of the machine's own two series, with a hole in it: the card's
    /// tiles draw stored history, and a picture that never shows a gap would
    /// not check the one property those charts exist to have.
    private static func previewMachineSlice(endingAt end: Date) -> HistorySlice {
        let tier = HistoryTier.minute
        var gpu: [HistorySample] = []
        var battery: [HistorySample] = []
        for minute in 0..<1_440 {
            // Asleep for two hours in the small hours, which is what leaves
            // the gap.
            if (300..<420).contains(minute) { continue }
            let at = end.addingTimeInterval(Double(minute - 1_440) * 60)
            let load = max(0, sin(Double(minute) / 90) * 0.5 + 0.15)
            gpu.append(
                HistorySample(
                    series: .gpuUtilisation,
                    timestamp: tier.bucketStart(of: at),
                    aggregate: Aggregate(minimum: load * 0.4, average: load, maximum: min(1, load * 1.6))
                )
            )
            // Draining, and charging over the last three hours.
            let charge = minute < 1_260 ? 0.95 - Double(minute) / 1_260 * 0.7 : 0.25 + Double(minute - 1_260) / 180 * 0.6
            battery.append(
                HistorySample(
                    series: .batteryCharge,
                    timestamp: tier.bucketStart(of: at),
                    aggregate: Aggregate(charge)
                )
            )
        }
        return HistorySlice(
            tier: tier,
            start: end.addingTimeInterval(-24 * 3600),
            end: end,
            rows: [.gpuUtilisation: gpu, .batteryCharge: battery]
        )
    }

    /// The four cards worth looking at, which are the four captions the strip
    /// can carry: gaps that mean only "did not rank", a pinned run reaching
    /// part of the way back, a pinned run that has since ended, and the same
    /// identity after it exited.
    private enum CardFate: String, CaseIterable {
        case live
        case pinned
        case unpinned
        case dead

        var isLive: Bool { self != .dead }
        /// Pinned *now*, which is what decides whether the promise runs to the
        /// leading edge or stops at the last bucket it covered.
        var isPinned: Bool { self == .pinned }
    }

    /// Which buckets a fate has pinned, by minute of the day the strip covers.
    private static func keep(_ fate: CardFate, minute: Int) -> ProcessKeepReason {
        switch fate {
        case .pinned: .pinned
        case .unpinned: (400..<480).contains(minute) ? .pinned : .ranked
        case .live, .dead: .ranked
        }
    }

    /// The card built from literals: a live family shaped like a browser — one
    /// root, helpers doing the work — and the same identity after it exited,
    /// when the strip is all that remains.
    @MainActor
    private static func previewProcessCard(_ fate: CardFate) -> ProcessCardModel {
        let end = Date(timeIntervalSince1970: 1_788_180_000)
        var points: [ProcessNamePoint] = []
        // `pinned` is pinned four hours ago and never ranked before it, so
        // every point it has is pinned and coverage can only be read off the
        // span. `unpinned` was pinned for a stretch in the middle of the day
        // and is not now, so the promise has both a beginning and an end.
        let humps =
            fate == .pinned
            ? [(1_200..<1_265, 0.7)]
            : [(60..<95, 0.55), (400..<480, 1.9), (1_200..<1_265, 0.7)]
        for (range, peak) in humps {
            for minute in range {
                let phase = Double(minute - range.lowerBound) / Double(range.count)
                let load = peak * exp(-pow((phase - 0.5) * 3.2, 2))
                points.append(
                    ProcessNamePoint(
                        bucketStart: end.addingTimeInterval(Double(minute - 1_440) * 60),
                        cpu: 0.05 + load,
                        footprint: UInt64(1.4e9 + load * 8e8),
                        diskRate: load * 2e5,
                        energy: (0.4 + load) * 60,
                        // The strip is captioned from these, so a pinned card's
                        // bars have to be what a pinned process really stores.
                        keep: keep(fate, minute: minute)
                    )
                )
            }
        }
        let history = ProcessNameHistory(tier: .minute, points: points)
        // The machine's own series behind the card's GPU and power tiles,
        // shaped like a day rather than read from the store: the harness runs
        // against whatever this Mac happens to have recorded, and a picture
        // that is empty on a fresh clone checks nothing.
        let machineSlice = previewMachineSlice(endingAt: end)
        // Only the unpinned live card carries a start count, so one render of
        // the set shows the badge and the rest show the header without it —
        // which is what a process that has simply been running looks like.
        let starts =
            fate == .live
            ? ProcessStarts(
                count: 14,
                from: end.addingTimeInterval(-14 * 3600),
                to: end
            )
            : nil
        // Summed from the same points, so the caption and the strip agree.
        let energy = ProcessEnergy(
            joules: points.reduce(0) { $0 + $1.energy },
            buckets: points.count,
            tier: .minute
        )

        // A defaults store per card, not the shared one: the models are built
        // before any of them is drawn, so a shared store would render whichever
        // state was set last, three times.
        let preferences = Preferences(
            defaults: UserDefaults(suiteName: "caliper.preview.card.\(fate.rawValue)") ?? .standard
        )
        preferences.setPinned(fate.isPinned, for: "Google Chrome")
        let family = ProcessFamilyKey.bundle(
            identifier: "com.google.Chrome",
            appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        )
        guard fate.isLive else {
            return ProcessCardModel(
                preloaded: .name("Google Chrome"),
                family: family,
                reading: nil,
                presence: .exited(lastSeen: end.addingTimeInterval(-600)),
                history: history,
                energy: energy,
                starts: starts,
            machineHistory: machineSlice,
                historyEnd: end,
                preferences: preferences
            )
        }

        func member(
            _ pid: pid_t,
            _ name: String,
            cpu: Double,
            footprint: Double,
            share: Double,
            gpu: Double,
            isRoot: Bool = false
        ) -> ProcessCardReading.Member {
            ProcessCardReading.Member(
                pid: pid,
                name: name,
                startTime: UInt64(pid) * 1_000,
                cpu: cpu,
                footprint: UInt64(footprint),
                lifetimeMaxFootprint: UInt64(footprint * 1.7),
                readRate: cpu * 3.5e6,
                writeRate: cpu * 1e6,
                power: cpu * 5.4,
                wakeupsPerSecond: cpu * 216,
                performanceCycleShare: share,
                qos: QoSBreakdown(
                    userInteractive: cpu * 0.35,
                    userInitiated: cpu * 0.05,
                    defaultTier: cpu * 0.3,
                    legacy: cpu * 0.04,
                    utility: cpu * 0.15,
                    background: cpu * 0.1,
                    maintenance: cpu * 0.01
                ),
                gpuTime: gpu,
                isRoot: isRoot,
                isOwnUser: true,
                runningFor: 3 * 3600 + 12 * 60
            )
        }

        let reading = ProcessCardReading(
            sampledAt: end,
            members: [
                member(84_112, "Google Chrome Helper (Renderer)", cpu: 0.184, footprint: 6.4e8, share: 0.74, gpu: 310),
                member(3_871, "Google Chrome Helper (GPU)", cpu: 0.091, footprint: 5.1e8, share: 0.66, gpu: 4_022),
                member(3_862, "Google Chrome", cpu: 0.045, footprint: 4.1e8, share: 0.71, gpu: 28, isRoot: true),
                member(88_214, "Google Chrome Helper (Renderer)", cpu: 0.018, footprint: 2.1e8, share: 0.52, gpu: 4),
                member(3_869, "Google Chrome Helper", cpu: 0.004, footprint: 1.3e8, share: 0.31, gpu: 0),
            ],
            performanceCycleShare: 0.72,
            gpuIsAvailable: true
        )
        return ProcessCardModel(
            preloaded: .pid(3_862, name: "Google Chrome"),
            family: family,
            reading: reading,
            presence: .live,
            history: history,
            energy: energy,
            starts: starts,
            machineHistory: machineSlice,
            historyEnd: end,
            preferences: preferences
        )
    }

    /// A defaults store of its own, so rendering the combined window cannot
    /// pick up — or write — whatever this Mac's own settings happen to be.
    @MainActor
    private static let previewPreferences = Preferences(
        defaults: UserDefaults(suiteName: "caliper.preview") ?? .standard
    )

    /// The three shapes a module can be configured into, rendered in full: a
    /// half on its own is where the layout goes wrong — a number clipped by a
    /// width measured for two things, a five-point gauge against its edge.
    private static let partVariants: [(name: String, parts: ModuleParts)] = [
        ("full", ModuleParts(isEnabled: true, graphic: .graph, showsValue: true)),
        ("graph", ModuleParts(isEnabled: true, graphic: .graph, showsValue: false)),
        ("icon", ModuleParts(isEnabled: true, graphic: .icon, showsValue: true)),
        ("icononly", ModuleParts(isEnabled: true, graphic: .icon, showsValue: false)),
        ("value", ModuleParts(isEnabled: true, graphic: .off, showsValue: true)),
    ]

    /// Scaled up to be judged, and over a mid grey because template images are
    /// pure alpha.
    @MainActor
    private static func write(
        _ image: NSImage,
        to url: URL,
        scale: Int = 3,
        background: NSColor? = NSColor(white: 0.35, alpha: 1)
    ) {
        let pixels = CGSize(width: image.size.width * CGFloat(scale), height: image.size.height * CGFloat(scale))
        guard
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixels.width),
                pixelsHigh: Int(pixels.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return }
        representation.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        if let background {
            background.setFill()
            CGRect(origin: .zero, size: image.size).fill()
        }
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func report(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Caliper: \(message)\n".utf8))
        exit(EXIT_SUCCESS)
    }
}
