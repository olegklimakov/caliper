import SwiftUI

/// One module's line of controls: whether it is in the strip, what it draws
/// there, whether its number comes with it, and a picture of the result.
///
/// Shared by the settings room and the first-run flow rather than written twice
/// — the rules about which control locks which are the fiddly part, and two
/// copies of them would disagree within a release.
struct MenuBarModuleRow: View {
    @Bindable var preferences: Preferences
    let metrics: LiveMetrics
    let module: MenuBarModule

    var body: some View {
        HStack(spacing: 12) {
            Toggle(module.title, isOn: enabledBinding)
                .frame(width: 104, alignment: .leading)
                .disabled(isLastEnabled)
            // Three states rather than a checkbox; see `IndicatorGraphic`.
            Picker("", selection: graphicBinding) {
                Text(module.graphTitle).tag(IndicatorGraphic.graph)
                Text("Icon").tag(IndicatorGraphic.icon)
                Text("Nothing").tag(IndicatorGraphic.off)
            }
            .labelsHidden()
            .frame(width: 116)
            .disabled(!preferences.menuBar[module].isEnabled)
            // A setting *of* the module beside it, not another module.
            Toggle(module.valueTitle, isOn: valueBinding)
                .toggleStyle(.checkbox)
                .frame(width: 112, alignment: .leading)
                .disabled(isValueLocked)
            Spacer(minLength: 8)
            MenuBarIndicatorPreview(
                module: module,
                parts: preferences.menuBar[module],
                coloured: preferences.colouredIndicators,
                metrics: metrics
            )
            .opacity(preferences.menuBar[module].isEnabled ? 1 : 0.35)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.menuBar[module].isEnabled },
            set: { preferences.menuBar[module].isEnabled = $0 }
        )
    }

    /// The last module stays: an empty strip has no button to right-click, and
    /// that menu is the only way to the settings and to Quit.
    private var isLastEnabled: Bool {
        preferences.menuBar.enabled == [module]
    }

    private var graphicBinding: Binding<IndicatorGraphic> {
        Binding(
            get: { preferences.menuBar[module].graphic },
            // The stored value refuses picture-and-number-off and hands the
            // number back, so the checkbox beside this ticks itself.
            set: { preferences.menuBar[module].graphic = $0 }
        )
    }

    private var valueBinding: Binding<Bool> {
        Binding(
            get: { preferences.menuBar[module].showsValue },
            set: { preferences.menuBar[module].showsValue = $0 }
        )
    }

    /// With nothing in the picture slot the number is all there is, so it
    /// cannot be switched off.
    private var isValueLocked: Bool {
        let parts = preferences.menuBar[module]
        return !parts.isEnabled || parts.graphic == .off
    }
}

/// The very image the menu bar will draw, at the size it will draw it —
/// rendered through the same indicator the status item uses, so there is no
/// second drawing to keep in step.
struct MenuBarIndicatorPreview: View {
    let module: MenuBarModule
    let parts: ModuleParts
    let coloured: Bool
    let metrics: LiveMetrics

    var body: some View {
        let indicator = module.indicator(parts: parts)
        Image(nsImage: indicator.makeImage(metrics, style: IndicatorStyle(isTemplate: !coloured)))
            .renderingMode(coloured ? .original : .template)
            // Reading the identity is what subscribes this view to the
            // metrics: `makeImage`'s drawing block runs when the image is
            // painted, after the body that would have tracked what it read.
            .id(indicator.identity(metrics))
            // Everything it shows is in the row's own checkboxes and in the
            // status item this is a picture of.
            .accessibilityHidden(true)
    }
}

/// The whole strip in one picture, drawn by `CombinedStrip` — the same code
/// that draws the shared status item.
///
/// The first-run flow's answer to "where does this app live": a screenshot
/// would go stale the moment the checkboxes below it are touched, and this one
/// is the real thing, live.
struct MenuBarStripPreview: View {
    let parts: MenuBarParts
    let coloured: Bool
    let metrics: LiveMetrics

    var body: some View {
        let indicators = parts.enabled.map { $0.indicator(parts: parts[$0]) }
        let style = IndicatorStyle(isTemplate: !coloured)
        Image(nsImage: CombinedStrip.image(of: indicators, state: metrics, style: style))
            .renderingMode(coloured ? .original : .template)
            .id(indicators.map { $0.identity(metrics) })
            .accessibilityHidden(true)
    }
}
