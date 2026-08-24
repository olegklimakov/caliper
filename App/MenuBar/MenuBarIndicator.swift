import AppKit

/// One module in the menu bar strip.
///
/// Indicators are pre-rendered images of a fixed width. Fixed, because a status
/// item that resizes with its value shoves everything to its left a few points
/// every second, and that jitter is the single most irritating thing a menu bar
/// monitor can do.
@MainActor
protocol MenuBarIndicator {
    var module: MenuBarModule { get }
    /// Which halves this one draws, and where they go. The width follows from
    /// it, which is why every indicator is handed one when it is made.
    var layout: IndicatorLayout { get }

    /// Everything that will be visible, reduced to a value that compares equal
    /// when the drawing would be identical. `nil` means the module has nothing
    /// to show and should disappear.
    ///
    /// The controller redraws only when this changes, so a machine sitting at
    /// the same rounded percentage costs nothing per tick.
    func identity(_ state: LiveMetrics) -> AnyHashable?

    func draw(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle)

    /// What the module's symbol is tinted with when it stands in for the live
    /// drawing — the accent, or whatever severity that drawing would have
    /// carried.
    func iconColour(_ state: LiveMetrics) -> NSColor

    /// What VoiceOver reads. The indicator is a drawn image with no text in it,
    /// so without this the whole module is silent — and it is the only thing
    /// this app puts on screen when nothing is open.
    func accessibilityLabel(_ state: LiveMetrics) -> String
}

/// The modules a user can put in the menu bar.
enum MenuBarModule: String, CaseIterable, Sendable {
    case cpu
    case memory
    case network
    case disk
    case temperature
}

/// What a module draws where its picture goes.
///
/// Three states rather than a switch, because switching the picture off is what
/// makes the number ambiguous: "8 %" and "65 %" side by side in the menu bar
/// are two anonymous percentages. The symbol is the cheap way to keep a number
/// named — twelve points against the sparkline's twenty-eight.
enum IndicatorGraphic: String, CaseIterable, Sendable {
    /// The live drawing: a sparkline, a gauge, a severity dot.
    case graph
    /// The symbol that names the module.
    case icon
    case off
}

/// What one module puts in the menu bar.
struct ModuleParts: Equatable, Sendable {
    /// Whether the module is in the menu bar at all. Here rather than in a list
    /// of its own: a module's presence and what it draws are the same
    /// question asked twice, and two answers can disagree.
    var isEnabled: Bool
    var graphic: IndicatorGraphic
    var showsValue: Bool

    /// What every module drew before any of this was configurable.
    static let shown = ModuleParts(isEnabled: true, graphic: .graph, showsValue: true)
    static let hidden = ModuleParts(isEnabled: false, graphic: .graph, showsValue: true)

    /// A module drawing neither is an empty status item holding a gap in the
    /// strip, which is the one combination that cannot be allowed.
    var isDrawable: Bool { graphic != .off || showsValue }

    init(isEnabled: Bool, graphic: IndicatorGraphic, showsValue: Bool) {
        self.isEnabled = isEnabled
        self.graphic = graphic
        self.showsValue = showsValue
    }

    /// Plist-native tokens: whether it is up there, what the picture is, and
    /// the number if it is drawn.
    init(stored: [String]) {
        isEnabled = stored.contains(Self.enabledToken)
        let states = Set([Self.enabledToken, Self.valueToken])
        graphic = IndicatorGraphic(rawValue: stored.first { !states.contains($0) } ?? "") ?? .off
        showsValue = stored.contains(Self.valueToken)
    }

    var stored: [String] {
        (isEnabled ? [Self.enabledToken] : [])
            + (graphic == .off ? [] : [graphic.rawValue])
            + (showsValue ? [Self.valueToken] : [])
    }

    private static let enabledToken = "enabled"
    private static let valueToken = "value"
}

/// The whole arrangement of the menu bar: which modules are in it, in what
/// order, and what each of them draws.
///
/// Total by construction: every module has an answer here, so nothing that
/// reads it has to decide what a missing one would mean. The repair, the
/// defaulting and the shape it is stored in all live in this one type — a fact
/// kept in one place and defaulted in three is three facts.
struct MenuBarParts: Equatable {
    private var parts: [MenuBarModule: ModuleParts]
    /// Every module, in the order the strip draws them.
    ///
    /// All of them, not only the ones switched on: a module that is off still
    /// has a place in the settings list, and it should come back where it was
    /// rather than at the end.
    private(set) var order: [MenuBarModule]

    /// The modules in the menu bar, in the order they are drawn.
    var enabled: [MenuBarModule] { order.filter { self[$0].isEnabled } }

    init() {
        order = MenuBarModule.allCases
        // Disk off to start with: four items is already a lot of menu bar, and
        // throughput is the one people look at least often.
        parts = order.reduce(into: [:]) { parts, module in
            parts[module] = module == .disk ? .hidden : .shown
        }
    }

    /// Whatever was stored, ignoring anything it cannot use: a module or a
    /// state this build no longer has, or a module left drawing nothing.
    init(stored: [String: [String]], order storedOrder: [String]) {
        self.init()
        let restored = storedOrder.compactMap(MenuBarModule.init(rawValue:))
        order = restored + MenuBarModule.allCases.filter { !restored.contains($0) }
        for module in MenuBarModule.allCases {
            guard let tokens = stored[module.rawValue] else { continue }
            self[module] = ModuleParts(stored: tokens)
        }
    }

    /// Plist types, so storing this is two `defaults.set` calls rather than a
    /// coder.
    var stored: [String: [String]] {
        parts.reduce(into: [:]) { stored, entry in
            stored[entry.key.rawValue] = entry.value.stored
        }
    }

    var storedOrder: [String] { order.map(\.rawValue) }

    subscript(module: MenuBarModule) -> ModuleParts {
        get { parts[module] ?? .shown }
        // The one place the "something has to be drawn" rule lives: asking for
        // no picture with no number gets the number back rather than an empty
        // status item.
        set {
            var parts = newValue
            if !parts.isDrawable { parts.showsValue = true }
            // And the strip itself cannot be emptied: with nothing in the menu
            // bar there is no button to right-click, and Settings and Quit live
            // in that menu — the app would still be running with no way back to
            // it.
            if !parts.isEnabled, enabled == [module] { parts.isEnabled = true }
            self.parts[module] = parts
        }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}

/// Where each half of an indicator goes, and what the whole thing measures.
///
/// The picture sits at the leading edge and the value is right-aligned at the
/// trailing one — which is how all five modules were already drawn. Writing it
/// down once gives a switched-off half somewhere to take its width from.
@MainActor
struct IndicatorLayout {
    let parts: ModuleParts
    /// The module's own drawing — the sparkline's width, the gauge's, the dot's.
    let graphWidth: CGFloat
    let valueWidth: CGFloat
    /// What separates that drawing from the number.
    let gap: CGFloat

    var showsGraph: Bool { parts.graphic == .graph }
    var showsGraphic: Bool { parts.graphic != .off }
    var showsValue: Bool { parts.showsValue }

    /// Points of menu bar this claims.
    ///
    /// Floored, because a lone graphic can be five points wide — the memory
    /// gauge is — and a status item that narrow is a click target nobody can
    /// hit.
    var width: CGFloat {
        var total = graphicWidth
        if showsValue {
            total += valueWidth
            if showsGraphic { total += graphicGap }
        }
        return max(total, MenuBarMetrics.minimumWidth)
    }

    /// Where the module draws its own picture, or `nil` when the slot holds a
    /// symbol or nothing at all.
    func graph(in bounds: CGRect) -> CGRect? {
        showsGraph ? graphicRect(in: bounds) : nil
    }

    /// Where the module's symbol goes. Drawn the same way for every module,
    /// which is why it is not the indicator's business.
    func icon(in bounds: CGRect) -> CGRect? {
        parts.graphic == .icon ? graphicRect(in: bounds) : nil
    }

    func value(in bounds: CGRect) -> CGRect? {
        guard showsValue else { return nil }
        return CGRect(
            x: bounds.maxX - valueWidth,
            y: bounds.minY,
            width: valueWidth,
            height: bounds.height
        )
    }

    private var graphicWidth: CGFloat {
        switch parts.graphic {
        case .graph: graphWidth
        case .icon: MenuBarMetrics.iconWidth
        case .off: 0
        }
    }

    /// A symbol needs more air beside a number than a sparkline does: the
    /// sparkline's own last pixels are usually blank, a glyph's are not.
    private var graphicGap: CGFloat {
        parts.graphic == .icon ? MenuBarMetrics.iconGap : gap
    }

    private func graphicRect(in bounds: CGRect) -> CGRect {
        // Centred when it is alone: the minimum width is padding, and a gauge
        // hung off the leading edge of it reads as a mistake.
        let x = showsValue ? bounds.minX : bounds.midX - graphicWidth / 2
        return CGRect(x: x, y: bounds.minY, width: graphicWidth, height: bounds.height)
    }
}

extension MenuBarModule {
    /// The renderer for this module, drawing the halves it was asked for.
    ///
    /// One factory rather than a table in the status bar controller: the
    /// settings screen renders the same images to preview them, and two lists
    /// of which module maps to which indicator would drift.
    @MainActor
    func indicator(parts: ModuleParts) -> any MenuBarIndicator {
        switch self {
        case .cpu: CPUIndicator(parts: parts)
        case .memory: MemoryIndicator(parts: parts)
        case .network: DualRateIndicator.network(parts: parts)
        case .disk: DualRateIndicator.disk(parts: parts)
        case .temperature: TemperatureIndicator(parts: parts)
        }
    }

    /// The symbol that names the module when its live drawing is not there.
    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .temperature: "thermometer.medium"
        }
    }

    /// The colour the module is drawn in, when colour is switched on.
    var accent: NSColor {
        switch self {
        case .cpu: Palette.cpu
        case .memory: Palette.memory
        case .network: Palette.networkDown
        case .disk: Palette.disk
        case .temperature: Palette.ok
        }
    }

    /// What this module's own drawing is called in its settings row. "Graph" is
    /// wrong for a gauge and for a severity dot, and a settings screen that
    /// calls every picture the same thing makes you switch one off to find out
    /// what it was.
    var graphTitle: String {
        switch self {
        case .memory: "Gauge"
        case .temperature: "Status dot"
        default: "Graph"
        }
    }

    /// And what its number is called.
    var valueTitle: String {
        switch self {
        case .network, .disk: "Rates"
        case .temperature: "Temperature"
        default: "Percentage"
        }
    }
}

/// Monochrome by default: a template image adopts the menu bar's own colour,
/// stays legible on every wallpaper, and is what the platform expects. Colour
/// is offered because these are metrics people scan rather than read.
struct IndicatorStyle {
    var isTemplate: Bool

    /// The colour to draw a metric's accent in, or black for template images —
    /// template rendering uses only the alpha channel, so the colour is
    /// irrelevant there but the shape is not.
    func accent(_ colour: NSColor) -> NSColor {
        isTemplate ? .black : colour
    }

    /// Secondary content — a sparkline behind a number, an upload line under a
    /// download one — needs to stay distinguishable in monochrome.
    func secondary(_ colour: NSColor) -> NSColor {
        isTemplate ? NSColor.black.withAlphaComponent(0.55) : colour
    }
}

extension MenuBarIndicator {
    /// Points of menu bar width this module claims, whatever the value.
    var width: CGFloat { layout.width }

    /// Most modules have no severity to carry, so their symbol is just the
    /// module's colour.
    func iconColour(_ state: LiveMetrics) -> NSColor { module.accent }

    /// Everything this module puts on screen, drawn into `bounds`.
    ///
    /// Separate from `draw` because the symbol is the same drawing for every
    /// module — done here rather than five times over in the indicators — and
    /// because the combined item draws each module into a slice of one image
    /// rather than into an image of its own.
    func render(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle) {
        if let icon = layout.icon(in: bounds) {
            MenuBarSymbol.draw(module.symbolName, in: icon, colour: style.accent(iconColour(state)))
        }
        draw(state, in: bounds, style: style)
    }

    /// Renders at the size the menu bar gives us, letting AppKit ask for the
    /// backing scale it needs rather than assuming @2x.
    func makeImage(_ state: LiveMetrics, style: IndicatorStyle) -> NSImage {
        let size = CGSize(width: width, height: MenuBarMetrics.imageHeight)
        let image = NSImage(size: size, flipped: false) { bounds in
            self.render(state, in: bounds, style: style)
            return true
        }
        image.isTemplate = style.isTemplate
        return image
    }
}

/// What the strip shows when no module has anything to say: at the cold start,
/// before the first sample, and on a machine whose every enabled module is
/// still silent.
///
/// Something rather than nothing, because a status item with no image has no
/// width, and an item with no width cannot be right-clicked — taking the menu
/// that holds Settings and Quit with it. Both arrangements need it: the
/// combined item is the only item there is, and separate items can all fall
/// silent at once.
@MainActor
enum MenuBarPlaceholder {
    static func image(style: IndicatorStyle) -> NSImage {
        let size = CGSize(width: MenuBarMetrics.minimumWidth, height: MenuBarMetrics.imageHeight)
        let image = NSImage(size: size, flipped: false) { bounds in
            MenuBarSymbol.draw(Self.symbol, in: bounds, colour: style.accent(.labelColor))
            return true
        }
        image.isTemplate = style.isTemplate
        return image
    }

    private static let symbol = "gauge.with.dots.needle.bottom.50percent"
}

/// The one image the modules share when they share a status item.
///
/// Here rather than in the status bar controller because the preview harness
/// renders the same strip, and a second copy of "how are the modules laid out
/// side by side" would be a second answer.
@MainActor
enum CombinedStrip {
    static func width(of indicators: [any MenuBarIndicator]) -> CGFloat {
        let gaps = CGFloat(max(0, indicators.count - 1)) * MenuBarMetrics.combinedGap
        return indicators.reduce(gaps) { $0 + $1.width }
    }

    static func image(
        of indicators: [any MenuBarIndicator],
        state: LiveMetrics,
        style: IndicatorStyle
    ) -> NSImage {
        let size = CGSize(width: width(of: indicators), height: MenuBarMetrics.imageHeight)
        let image = NSImage(size: size, flipped: false) { bounds in
            var x = bounds.minX
            for indicator in indicators {
                indicator.render(
                    state,
                    in: CGRect(x: x, y: bounds.minY, width: indicator.width, height: bounds.height),
                    style: style
                )
                x += indicator.width + MenuBarMetrics.combinedGap
            }
            return true
        }
        image.isTemplate = style.isTemplate
        return image
    }
}

/// Draws an SF Symbol into a menu bar indicator.
@MainActor
enum MenuBarSymbol {
    static func draw(_ name: String, in rect: CGRect, colour: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return }

        // Fitted rather than stretched: these glyphs are not all square, and a
        // wide one drawn to the slot's width would lean into the number.
        let size = symbol.size
        let scale = min(rect.width / size.width, rect.height / size.height, 1)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        symbol.draw(
            in: CGRect(
                x: rect.midX - fitted.width / 2,
                y: rect.midY - fitted.height / 2,
                width: fitted.width,
                height: fitted.height
            )
        )
    }
}

@MainActor
enum MenuBarMetrics {
    /// The bar is 24 points tall; 18 is what fits without crowding the edges.
    static let imageHeight: CGFloat = 18
    /// Narrower than this and the status item stops being clickable, whatever
    /// it has been asked to draw.
    static let minimumWidth: CGFloat = 18
    /// A symbol standing in for the live drawing, and the air it needs beside
    /// the number.
    static let iconWidth: CGFloat = 12
    static let iconGap: CGFloat = 4
    /// What separates two modules inside the combined item. Wider than the gap
    /// inside a module, so the strip still reads as several readings rather
    /// than one long number.
    static let combinedGap: CGFloat = 9
    /// Digits are monospaced so a changing value never nudges its neighbours.
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let smallValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
}
