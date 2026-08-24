import AppKit
import CaliperCore

/// Owns the menu bar strip, in one of two arrangements.
///
/// Separate items are the default: macOS then gives reordering (⌘-drag) and
/// per-module click targets for free, and a module the user turns off simply
/// stops existing. Combined draws the same indicators into one item, which
/// costs ⌘-drag — the order becomes ours to keep — and buys back the width of
/// four status items and the four click targets nobody was aiming at.
@MainActor
final class StatusItemController {
    private let state: LiveMetrics
    private var items: [MenuBarModule: NSStatusItem] = [:]
    /// The one item, when the modules share it.
    private var combinedItem: NSStatusItem?
    private var lastIdentity: [MenuBarModule: AnyHashable] = [:]
    private var lastCombinedIdentity: AnyHashable?
    private var style = IndicatorStyle(isTemplate: true)
    private var lastRedraw: ContinuousClock.Instant?

    /// How often the strip is allowed to redraw.
    ///
    /// Measured: handing a status item a new image costs about 0.75 % of a core
    /// per second — layer update and a round trip to the window server, almost
    /// none of it our drawing. A scrolling sparkline changes every tick by
    /// definition, so the only lever is how often it is pushed. Two seconds
    /// while nobody has a panel open is the difference between fitting the
    /// footprint budget and not; with a panel open, where someone is watching
    /// the numbers move, it goes back to every tick.
    private var redrawInterval: Duration = .seconds(2)

    /// Rebuilt whenever the parts change: an indicator is told which halves it
    /// draws when it is made, because that is also what decides its width.
    private var indicators: [MenuBarModule: any MenuBarIndicator] = [:]
    private var parts = MenuBarParts()
    private var combines = false
    /// Whether the strip is wearing the update dot. A scheduled check that
    /// finds something says so here rather than by opening a window; see
    /// `UpdaterService.supportsGentleScheduledUpdateReminders`.
    private var isUpdateAvailable = false

    /// Called when a module's button is clicked, with the button to anchor a
    /// popover to. Set by the app delegate, which owns the panels.
    var onSelect: ((MenuBarModule, NSStatusBarButton) -> Void)?

    /// Called when the combined item is clicked. It stands for every module at
    /// once, so it opens the window that shows every module at once.
    var onSelectCombined: ((NSStatusBarButton) -> Void)?

    /// Called when the menu's Settings item is picked.
    var onOpenSettings: (() -> Void)?

    /// Called when the menu's Check for Updates item is picked.
    var onCheckForUpdates: (() -> Void)?

    /// Shares one metrics store with the panels: they show the same numbers,
    /// and two stores would guarantee they disagree by a tick.
    init(metrics: LiveMetrics, layout: MenuBarParts, combined: Bool) {
        self.state = metrics
        apply(layout, combined: combined)
    }

    /// The arrangement, in one call: every preference writes through one
    /// callback, and the modules, their parts and whether they share an item
    /// are three answers to the same question.
    func setLayout(_ parts: MenuBarParts, combined: Bool) {
        guard parts != self.parts || combined != self.combines else { return }
        apply(parts, combined: combined)
    }

    /// The update dot, on or off. Redraws through `forgetDrawings` because the
    /// badge is part of the image, and the identity that decides whether to
    /// redraw knows only about the reading.
    func setUpdateAvailable(_ available: Bool) {
        guard available != isUpdateAvailable else { return }
        isUpdateAvailable = available
        forgetDrawings()
        refresh()
    }

    func setColoured(_ coloured: Bool) {
        guard style.isTemplate == coloured else { return }
        style = IndicatorStyle(isTemplate: !coloured)
        forgetDrawings()  // Force a redraw in the new style.
        refresh()
    }

    /// Called after the shared store has taken the snapshot.
    func snapshotDidChange() {
        let now = ContinuousClock.now
        if let lastRedraw, now - lastRedraw < redrawInterval { return }
        lastRedraw = now
        refresh()
    }

    /// Live values are worth their cost while a panel is open.
    func setLive(_ live: Bool) {
        redrawInterval = live ? .seconds(1) : .seconds(2)
        lastRedraw = nil
    }

    // MARK: - Arrangement

    private func apply(_ parts: MenuBarParts, combined: Bool) {
        self.parts = parts
        self.combines = combined
        // Before the items: adding one asks its indicator how wide it is.
        indicators = MenuBarModule.allCases.reduce(into: [:]) { indicators, module in
            indicators[module] = module.indicator(parts: parts[module])
        }
        if combined {
            for module in items.keys { remove(module) }
            if combinedItem == nil { combinedItem = makeItem(identifier: Self.combinedIdentifier) }
        } else {
            if let combinedItem {
                NSStatusBar.system.removeStatusItem(combinedItem)
                self.combinedItem = nil
            }
            let enabled = parts.enabled
            for module in items.keys where !enabled.contains(module) {
                remove(module)
            }
            for module in enabled where items[module] == nil {
                add(module)
            }
        }
        forgetDrawings()
        // Drawn now rather than at the next tick: two seconds is a long time to
        // leave an item that has just been created or resized showing nothing.
        refresh()
    }

    /// Both the width and the content may have changed; `refresh` re-assigns
    /// `item.length` from the new indicator as it redraws.
    private func forgetDrawings() {
        lastIdentity.removeAll()
        lastCombinedIdentity = nil
    }

    // MARK: - Drawing

    private func refresh() {
        if let combinedItem {
            refreshCombined(combinedItem)
        } else {
            refreshSeparate()
        }
    }

    private func refreshSeparate() {
        // Walked in the strip's own order, so the item that stands in for a
        // silent strip is its first one rather than whichever the dictionary
        // happened to hand over first.
        var silent = true
        for module in parts.enabled {
            guard let item = items[module], let indicator = indicators[module] else { continue }

            guard let identity = indicator.identity(state) else {
                // Nothing to show — a machine with no sensors, or a metric that
                // has not produced its first reading yet.
                hide(item)
                lastIdentity[module] = nil
                continue
            }
            silent = false
            // Ahead of the identity check, not inside it: the label carries the
            // reading whether or not the picture drew it, and a module showing
            // only its symbol has an identity that never moves — which would
            // leave VoiceOver reading the first sample out for the rest of the
            // session. The image is what the identity is there to spare.
            speak(indicator.accessibilityLabel(state), from: item)

            guard lastIdentity[module] != identity else { continue }
            lastIdentity[module] = identity
            let (image, width) = badged(
                indicator.makeImage(state, style: style),
                width: indicator.width,
                if: module == parts.enabled.first
            )
            item.length = width
            item.button?.image = image
        }

        guard silent, let first = parts.enabled.first, let item = items[first] else { return }
        let identity = AnyHashable(Self.placeholderIdentity)
        guard lastIdentity[first] != identity else { return }
        lastIdentity[first] = identity
        drawPlaceholder(into: item)
    }

    private func refreshCombined(_ item: NSStatusItem) {
        // Only the modules with something to say: one that has not produced a
        // reading yet leaves no gap in the strip, the way its own item would
        // simply not be there.
        var drawn: [any MenuBarIndicator] = []
        var identities: [AnyHashable] = []
        for module in parts.enabled {
            guard let indicator = indicators[module], let identity = indicator.identity(state)
            else { continue }
            drawn.append(indicator)
            identities.append(identity)
        }
        guard !drawn.isEmpty else {
            let identity = AnyHashable(Self.placeholderIdentity)
            guard lastCombinedIdentity != identity else { return }
            lastCombinedIdentity = identity
            drawPlaceholder(into: item)
            return
        }

        // One item speaking for all of them: VoiceOver reads the strip in the
        // order it is drawn, which is the order the settings list shows. Said
        // before the identity check for the reason the separate items say it
        // there — a strip of symbols alone has an identity that stands still
        // while the readings behind it move.
        speak(drawn.map { $0.accessibilityLabel(state) }.joined(separator: ", "), from: item)

        let identity = AnyHashable(identities)
        guard lastCombinedIdentity != identity else { return }
        lastCombinedIdentity = identity

        let (image, width) = badged(
            CombinedStrip.image(of: drawn, state: state, style: style),
            width: CombinedStrip.width(of: drawn),
            if: true
        )
        item.length = width
        item.button?.image = image
    }

    /// One dot for the whole strip, on the item that carries it — the first in
    /// the separate arrangement, the only one in the combined. Four items
    /// wearing four dots would read as four updates.
    ///
    /// Image and width together, because the dot takes room of its own and an
    /// item drawn wider than it was sized for is an item with its dot cropped
    /// off.
    private func badged(
        _ image: NSImage,
        width: CGFloat,
        if isTheOne: Bool
    ) -> (NSImage, CGFloat) {
        guard isUpdateAvailable, isTheOne else { return (image, width) }
        return (MenuBarBadge.over(image, style: style), width + MenuBarBadge.width)
    }

    /// The one thing a drawn image cannot carry. Label and tooltip are the same
    /// sentence: the strip draws no text, so what VoiceOver reads and what the
    /// pointer reveals are both the reading spelled out.
    private func speak(_ label: String, from item: NSStatusItem) {
        item.button?.setAccessibilityLabel(label)
        item.button?.toolTip = label
    }

    private func drawPlaceholder(into item: NSStatusItem) {
        let (image, width) = badged(
            MenuBarPlaceholder.image(style: style),
            width: MenuBarMetrics.minimumWidth,
            if: true
        )
        item.length = width
        item.button?.image = image
        speak("Caliper, no readings yet", from: item)
    }

    private func hide(_ item: NSStatusItem) {
        item.button?.image = nil
        item.length = 0
        // And says nothing: a zero-width item that still carries a label reads
        // its last measurement out to VoiceOver forever.
        item.button?.setAccessibilityLabel(nil)
        item.button?.toolTip = nil
    }

    // MARK: - Items

    private func add(_ module: MenuBarModule) {
        guard let indicator = indicators[module] else { return }
        let item = makeItem(identifier: module.rawValue)
        item.length = indicator.width
        item.button?.toolTip = module.title
        items[module] = item
    }

    private func makeItem(identifier: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
        // Right-click opens the menu, left-click opens the panel. A status item
        // with a `menu` set never reports clicks at all, so the two have to be
        // told apart here.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    private func remove(_ module: MenuBarModule) {
        guard let item = items.removeValue(forKey: module) else { return }
        NSStatusBar.system.removeStatusItem(item)
        lastIdentity[module] = nil
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
            return
        }
        guard let raw = sender.identifier?.rawValue else { return }
        if raw == Self.combinedIdentifier {
            onSelectCombined?(sender)
        } else if let module = MenuBarModule(rawValue: raw) {
            onSelect?(module, sender)
        }
    }

    /// Settings and Quit. An app with no Dock icon and no window has nowhere
    /// else to put them, and without a Quit item the only way to stop Caliper
    /// would be Activity Monitor.
    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        // Named for what it will do rather than what it is: with the dot
        // showing, the answer is already known and the item is the way to see
        // it. This menu is the only one an accessory app draws, so it is also
        // the only place the dot can be acted on.
        menu.addItem(
            withTitle: isUpdateAvailable ? "Update Available…" : "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Caliper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Attaching the menu makes the item show it and then detaching keeps
        // left-clicks working as panel toggles.
        let item = combinedItem?.button === button
            ? combinedItem
            : items.first { $0.value.button === button }?.value
        item?.menu = menu
        button.performClick(nil)
        item?.menu = nil
    }

    /// Asked of the app rather than sent into the responder chain.
    ///
    /// This used to be `NSApp.sendAction(Selector(("showSettingsWindow:")))`,
    /// which is how a SwiftUI `Settings` scene is opened from AppKit — and it
    /// did nothing. The action *was* delivered: `target(forAction:)` finds
    /// SwiftUI's own app delegate, which then ignored it, and no window was ever
    /// created. The settings are a room of the history window now, and the app
    /// opens its own windows.
    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    private static let combinedIdentifier = "combined"
    private static let placeholderIdentity = "placeholder"
}

extension MenuBarModule {
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .temperature: "Sensors"
        }
    }
}
