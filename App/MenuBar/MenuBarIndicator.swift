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

    /// Everything visible, reduced to a value that compares equal when the
    /// drawing would be identical; `nil` to disappear. The controller redraws
    /// only when it changes, so a steady reading costs nothing per tick.
    func identity(_ state: LiveMetrics) -> AnyHashable?

    func draw(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle)

    /// The accent, or whatever severity the live drawing would have carried.
    func iconColour(_ state: LiveMetrics) -> NSColor

    /// The indicator is a drawn image with no text in it, so without this the
    /// module is silent to VoiceOver.
    func accessibilityLabel(_ state: LiveMetrics) -> String
}

enum MenuBarModule: String, CaseIterable, Sendable {
    case cpu
    case memory
    case network
    case disk
    case temperature
}

/// What a module draws where its picture goes.
///
/// Three states rather than a flag: with the picture off, "8 %" and "65 %" side
/// by side are two anonymous percentages. The symbol keeps a number named for
/// twelve points against the sparkline's twenty-eight.
enum IndicatorGraphic: String, CaseIterable, Sendable {
    /// A sparkline, a gauge, a severity dot.
    case graph
    /// The symbol that names the module.
    case icon
    case off
}

struct ModuleParts: Equatable, Sendable {
    /// Here rather than in a list of its own: a module's presence and what it
    /// draws are the same question, and two answers can disagree.
    var isEnabled: Bool
    var graphic: IndicatorGraphic
    var showsValue: Bool

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

    /// Plist-native tokens.
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

/// The whole arrangement of the menu bar. Total by construction — every module
/// has an answer here, so nothing that reads it has to decide what a missing one
/// would mean. Repair, defaulting and storage all live in this one type.
struct MenuBarParts: Equatable {
    private var parts: [MenuBarModule: ModuleParts]
    /// Every module, including the switched-off ones: they still have a place in
    /// the settings list, and should come back where they were.
    private(set) var order: [MenuBarModule]

    var enabled: [MenuBarModule] { order.filter { self[$0].isEnabled } }

    init() {
        order = MenuBarModule.allCases
        // Disk off to start with: four items is already a lot of menu bar, and
        // throughput is the one people look at least often.
        parts = order.reduce(into: [:]) { parts, module in
            parts[module] = module == .disk ? .hidden : .shown
        }
    }

    /// Whatever was stored, ignoring anything this build cannot use.
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
        // Asking for no picture and no number gets the number back rather than
        // an empty status item.
        set {
            var parts = newValue
            if !parts.isDrawable { parts.showsValue = true }
            // And the strip cannot be emptied: Settings and Quit live in the
            // right-click menu, so an empty strip is an app with no way back.
            if !parts.isEnabled, enabled == [module] { parts.isEnabled = true }
            self.parts[module] = parts
        }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}

/// Where each half of an indicator goes: picture at the leading edge, value
/// right-aligned at the trailing one. Written down once so a switched-off half
/// has somewhere to take its width from.
@MainActor
struct IndicatorLayout {
    let parts: ModuleParts
    /// The sparkline's width, the gauge's, the dot's.
    let graphWidth: CGFloat
    let valueWidth: CGFloat
    let gap: CGFloat

    var showsGraph: Bool { parts.graphic == .graph }
    var showsGraphic: Bool { parts.graphic != .off }
    var showsValue: Bool { parts.showsValue }

    /// Floored, because a lone graphic can be five points wide — the memory
    /// gauge is — and that narrow is a click target nobody can hit.
    var width: CGFloat {
        var total = graphicWidth
        if showsValue {
            total += valueWidth
            if showsGraphic { total += graphicGap }
        }
        return max(total, MenuBarMetrics.minimumWidth)
    }

    func graph(in bounds: CGRect) -> CGRect? {
        showsGraph ? graphicRect(in: bounds) : nil
    }

    /// Drawn the same way for every module, which is why it is not the
    /// indicator's business.
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
    /// One factory rather than a table in the status bar controller: the
    /// settings screen renders the same images to preview them.
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

    /// Stands in for the live drawing.
    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .temperature: "thermometer.medium"
        }
    }

    var accent: NSColor {
        switch self {
        case .cpu: Palette.cpu
        case .memory: Palette.memory
        case .network: Palette.networkDown
        case .disk: Palette.disk
        case .temperature: Palette.ok
        }
    }

    /// "Graph" is wrong for a gauge and for a severity dot, and a settings
    /// screen that calls every picture the same thing makes you switch one off
    /// to find out what it was.
    var graphTitle: String {
        switch self {
        case .memory: "Gauge"
        case .temperature: "Status dot"
        default: "Graph"
        }
    }

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

    /// Black for template images: that rendering uses only the alpha channel.
    func accent(_ colour: NSColor) -> NSColor {
        isTemplate ? .black : colour
    }

    /// A sparkline behind a number, an upload line under a download one: it has
    /// to stay distinguishable in monochrome.
    func secondary(_ colour: NSColor) -> NSColor {
        isTemplate ? NSColor.black.withAlphaComponent(0.55) : colour
    }
}

extension MenuBarIndicator {
    var width: CGFloat { layout.width }

    /// Most modules have no severity to carry.
    func iconColour(_ state: LiveMetrics) -> NSColor { module.accent }

    /// Separate from `draw`: the symbol is the same drawing for every module,
    /// and the combined item renders each into a slice of one image.
    func render(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle) {
        if let icon = layout.icon(in: bounds) {
            MenuBarSymbol.draw(module.symbolName, in: icon, colour: style.accent(iconColour(state)))
        }
        draw(state, in: bounds, style: style)
    }

    /// Sized in points, so AppKit asks for the backing scale it needs rather
    /// than being assumed @2x.
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

/// What the strip shows before the first sample, or when every enabled module
/// is silent. Something rather than nothing: an item with no image has no
/// width, and an item with no width cannot be right-clicked — taking Settings
/// and Quit with it.
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

/// The dot the strip wears while an update is waiting.
///
/// Its own space at the trailing edge, never laid over the drawing: the top
/// corner collides with the temperature module's degree sign, and a notice that
/// eats a digit is worse than no notice. The item does get wider while it is up
/// — the one jitter the fixed widths allow, twice per update rather than twice
/// a second.
@MainActor
enum MenuBarBadge {
    static let width: CGFloat = diameter + gap

    static func over(_ image: NSImage, style: IndicatorStyle) -> NSImage {
        let size = CGSize(width: image.size.width + width, height: image.size.height)
        let badged = NSImage(size: size, flipped: false) { bounds in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let dot = CGRect(
                x: bounds.maxX - diameter,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            style.accent(.controlAccentColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        // Follows the image it extends: a badge that opted out would be the
        // one coloured thing in a monochrome strip.
        badged.isTemplate = image.isTemplate
        return badged
    }

    private static let diameter: CGFloat = 5
    private static let gap: CGFloat = 3
}

/// The one image the modules share when they share a status item. Here rather
/// than in the status bar controller because the preview harness renders the
/// same strip.
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
