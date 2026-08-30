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
        let load: [(String, Double, UInt64)] = [
            ("Xcode", 3.4, 1_100_000_000),
            ("swift-frontend", 2.1, 620_000_000),
            ("com.apple.WebKit.WebContent", 0.7, 4_300_000_000),
            ("Brave Browser Helper (Renderer)", 0.2, 2_600_000_000),
            ("kernel_task", 0.4, 180_000_000),
            ("WindowServer", 0.3, 410_000_000),
            ("Telegram", 0.1, 830_000_000),
        ]
        // Two sweeps in one bucket, so the stored numbers are a mean of more
        // than one reading.
        for offset in [0.0, 15.0] {
            recorder.record(
                ProcessesSample(
                    sampledAt: cursor.addingTimeInterval(offset),
                    topByCPU: load.enumerated().map { index, entry in
                        ProcessSample(
                            pid: Int32(index + 1),
                            name: entry.0,
                            cpu: entry.1 * (offset == 0 ? 1.1 : 0.9),
                            memoryFootprint: entry.2,
                            diskRate: 0,
                            power: 0,
                            wakeupsPerSecond: 0,
                            performanceCycleShare: nil,
                            qos: nil
                        )
                    },
                    topByMemory: [],
                    topByDisk: [],
                    topByPower: [],
                    unreadableCount: 0
                )
            )
        }
        guard (try? recorder.flushNow()) != nil else { return nil }
        return try? await reader.consumers(at: cursor, retention: .week)
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
