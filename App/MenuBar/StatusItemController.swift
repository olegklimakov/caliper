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
    /// definition, so the only lever is how often it is pushed. Two seconds is
    /// the difference between fitting the footprint budget and not. Do not
    /// quicken it while a panel is open: the panel covers the strip.
    private static let redrawInterval: Duration = .seconds(2)

    /// Rebuilt whenever the parts change: an indicator is told which halves it
    /// draws when it is made, because that is also what decides its width.
    private var indicators: [MenuBarModule: any MenuBarIndicator] = [:]
    private var parts = MenuBarParts()
    private var combines = false
    /// A scheduled check that finds something says so here rather than by
    /// opening a window; see
    /// `UpdaterService.supportsGentleScheduledUpdateReminders`.
    private var isUpdateAvailable = false

    /// The button is what a popover anchors to. Set by the app delegate, which
    /// owns the panels.
    var onSelect: ((MenuBarModule, NSStatusBarButton) -> Void)?
    /// The combined item stands for every module, so it opens the window that
    /// shows every module.
    var onSelectCombined: ((NSStatusBarButton) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    /// Shares one metrics store with the panels: two stores would guarantee
    /// they disagree by a tick.
    init(metrics: LiveMetrics, layout: MenuBarParts, combined: Bool) {
        self.state = metrics
        apply(layout, combined: combined)
    }

    /// One call, because the modules, their parts and whether they share an
    /// item are three answers to the same question.
    func setLayout(_ parts: MenuBarParts, combined: Bool) {
        guard parts != self.parts || combined != self.combines else { return }
        apply(parts, combined: combined)
    }

    /// Redraws through `forgetDrawings` because the badge is part of the image,
    /// and the identity that gates a redraw knows only about the reading.
    func setUpdateAvailable(_ available: Bool) {
        guard available != isUpdateAvailable else { return }
        isUpdateAvailable = available
        forgetDrawings()
        refresh()
    }

    func setColoured(_ coloured: Bool) {
        guard style.isTemplate == coloured else { return }
        style = IndicatorStyle(isTemplate: !coloured)
        forgetDrawings()
        refresh()
    }

    func snapshotDidChange() {
        let now = ContinuousClock.now
        if let lastRedraw, now - lastRedraw < Self.redrawInterval { return }
        lastRedraw = now
        refresh()
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
        // Now rather than at the next tick: two seconds is a long time to leave
        // an item that was just created or resized showing nothing.
        refresh()
    }

    /// Width as well as content; `refresh` re-assigns `item.length` from the
    /// new indicator as it redraws.
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
        // Every module is asked what it has before anything is written: two of
        // the answers depend on all of them — which item wears the update dot,
        // and whether the strip is silent enough to need its stand-in. Deciding
        // those inside the walk has each undo the other's bookkeeping. Read
        // once, because `enabled` filters into a fresh array per call.
        let enabled = parts.enabled
        var identities: [MenuBarModule: AnyHashable] = [:]
        for module in enabled {
            // The item as well as the indicator: a module with nowhere to
            // draw can be neither the dot's host nor the stand-in.
            guard items[module] != nil, let indicator = indicators[module] else { continue }
            identities[module] = indicator.identity(state)
        }

        // The first that *draws*, not the first enabled: with Sensors dragged
        // to the front of a Mac that reports none, the leading item is hidden
        // and a dot on it is a dot on nothing.
        let firstDrawn = enabled.first { identities[$0] != nil }
        // The strip's own order, not the dictionary's. The stand-in is drawn
        // *instead* of the item being hidden, never both.
        let standIn = firstDrawn == nil ? enabled.first(where: { items[$0] != nil }) : nil

        for module in enabled {
            guard let item = items[module], let indicator = indicators[module] else { continue }

            if module == standIn {
                guard lastIdentity[module] != Self.placeholderIdentity else { continue }
                lastIdentity[module] = Self.placeholderIdentity
                drawPlaceholder(into: item)
                continue
            }

            guard let identity = identities[module] else {
                // Nothing to show — no sensors, or no first reading yet.
                // Recorded as a state rather than by clearing the entry, so
                // that re-hiding a hidden item costs no AppKit writes.
                guard lastIdentity[module] != Self.hiddenIdentity else { continue }
                lastIdentity[module] = Self.hiddenIdentity
                hide(item)
                continue
            }

            // Ahead of the identity check: a module showing only its symbol
            // has an identity that never moves, which would leave VoiceOver
            // reading the first sample out forever.
            speak(indicator.accessibilityLabel(state), from: item)

            guard lastIdentity[module] != identity else { continue }
            lastIdentity[module] = identity
            draw(
                indicator.makeImage(state, style: style),
                width: indicator.width,
                into: item,
                badged: module == firstDrawn
            )
        }
    }

    private func refreshCombined(_ item: NSStatusItem) {
        // Only the modules with something to say, so one without a reading
        // leaves no gap.
        var drawn: [any MenuBarIndicator] = []
        var identities: [AnyHashable] = []
        for module in parts.enabled {
            guard let indicator = indicators[module], let identity = indicator.identity(state)
            else { continue }
            drawn.append(indicator)
            identities.append(identity)
        }
        guard !drawn.isEmpty else {
            guard lastCombinedIdentity != Self.placeholderIdentity else { return }
            lastCombinedIdentity = Self.placeholderIdentity
            drawPlaceholder(into: item)
            return
        }

        // Read in the order it is drawn, which is the order the settings list
        // shows. Before the identity check, for the reason above.
        speak(drawn.map { $0.accessibilityLabel(state) }.joined(separator: ", "), from: item)

        let identity = AnyHashable(identities)
        guard lastCombinedIdentity != identity else { return }
        lastCombinedIdentity = identity

        draw(
            CombinedStrip.image(of: drawn, state: state, style: style),
            width: CombinedStrip.width(of: drawn),
            into: item,
            badged: true
        )
    }

    /// Image and length in one call: the dot takes room of its own, and an item
    /// sized for the drawing it had before the dot has the dot cropped off.
    ///
    /// `badged` says only whether this item is *allowed* to wear it — four items
    /// wearing four dots would read as four updates.
    private func draw(
        _ image: NSImage,
        width: CGFloat,
        into item: NSStatusItem,
        badged: Bool
    ) {
        let wearsBadge = isUpdateAvailable && badged
        // Only when it moves: re-stating the length costs a second
        // window-server round trip per module, and each relays every item to
        // its left.
        let length = wearsBadge ? width + MenuBarBadge.width : width
        if item.length != length {
            item.length = length
        }
        item.button?.image = wearsBadge ? MenuBarBadge.over(image, style: style) : image
    }

    /// Label and tooltip are the same sentence — the strip draws no text.
    ///
    /// Guarded on the text rather than on the redraw: assigning a tooltip tears
    /// down the button's tracking rectangle and installs a new one, so
    /// repeating yesterday's sentence twice a second is not free. The tooltip
    /// is the whole state; the two are only ever set together.
    private func speak(_ label: String, from item: NSStatusItem) {
        guard let button = item.button, button.toolTip != label else { return }
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func drawPlaceholder(into item: NSStatusItem) {
        draw(
            MenuBarPlaceholder.image(style: style),
            width: MenuBarMetrics.minimumWidth,
            into: item,
            badged: true
        )
        speak("Caliper, no readings yet", from: item)
    }

    private func hide(_ item: NSStatusItem) {
        item.button?.image = nil
        item.length = 0
        // A zero-width item that still carries a label reads its last
        // measurement out to VoiceOver forever.
        item.button?.setAccessibilityLabel(nil)
        item.button?.toolTip = nil
    }

    // MARK: - Items

    private func add(_ module: MenuBarModule) {
        guard let indicator = indicators[module] else { return }
        let item = makeItem(identifier: module.rawValue)
        item.length = indicator.width
        // No placeholder tooltip: `speak` skips when the sentence has not
        // moved, so seeding it with the module's name would swallow a first
        // real sentence that happens to be that name ("Sensors", before the
        // first temperature). The refresh in `apply` fills both in anyway.
        items[module] = item
    }

    private func makeItem(identifier: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
        // A status item with a `menu` set never reports clicks, so right-click
        // (menu) and left-click (panel) have to be told apart here.
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

    /// Settings and Quit. An accessory app draws no main menu, so without this
    /// the only way to quit Caliper would be Activity Monitor.
    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        // With the dot showing the answer is already known, so the item is
        // named for what it will do. The only place the dot can be acted on.
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

        // Attach to show, detach to keep left-clicks working as panel toggles.
        let item = combinedItem?.button === button
            ? combinedItem
            : items.first { $0.value.button === button }?.value
        item?.menu = menu
        button.performClick(nil)
        item?.menu = nil
    }

    /// Asked of the app, not sent into the responder chain. `NSApp.sendAction`
    /// with `showSettingsWindow:` delivers to SwiftUI's app delegate, which
    /// ignores it, and no window is ever created.
    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    private static let combinedIdentifier = "combined"
    /// The two non-reading states, as identities like any other: arriving costs
    /// one write, staying costs none.
    private static let placeholderIdentity = AnyHashable("placeholder")
    private static let hiddenIdentity = AnyHashable("hidden")
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
