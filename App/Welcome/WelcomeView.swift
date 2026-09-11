import AppKit
import SwiftUI

/// The first run, drawn in place of the history window's split view.
///
/// In that window rather than one of its own, because the thing a new install
/// most needs to know is that this window exists and how to get back to it —
/// and a separate window that closes for good would have taught the opposite.
///
/// Everything here edits the live preferences, so the strip up in the menu bar
/// changes as the switches are clicked. That is the whole argument for
/// onboarding a menu bar app: the subject is thirty points of screen the user
/// has never seen, and the only convincing way to describe it is to let them
/// watch it move.
struct WelcomeView: View {
    @Bindable var preferences: Preferences
    let metrics: LiveMetrics

    @State private var step: WelcomeStep.Step = .place

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                WelcomeStep(preferences: preferences, metrics: metrics, step: step)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var footer: some View {
        HStack {
            if step == .strip {
                Button("Back") { step = .place }
            }
            Spacer()
            switch step {
            case .place:
                // Prominent but *not* the default action, which is the one
                // thing it must not be: a single Return fired this and the
                // button that replaced it, both — measured, one press, and the
                // flow was over. Only the step that ends it answers to Return.
                Button("Continue") { step = .strip }
                    .buttonStyle(.borderedProminent)
            case .strip:
                // The one button that writes `completedSetup`; closing the
                // window instead leaves the flow to be met again next launch,
                // which is the right answer for someone who has not chosen yet.
                Button("Done") { preferences.completeSetup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// One step of the first run, without the flow around it.
///
/// Internal, and split from `WelcomeView` for the same reason `DashboardPane`
/// is: `ImageRenderer` draws a `ScrollView` as an empty rectangle, so the
/// preview harness renders the step and not the screen.
struct WelcomeStep: View {
    enum Step: String, CaseIterable {
        case place
        case strip
    }

    @Bindable var preferences: Preferences
    let metrics: LiveMetrics
    let step: Step

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .place: place
            case .strip: strip
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Where it lives

    private var place: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            Text("Caliper is running")
                .font(.system(size: 22, weight: .semibold))

            menuBarPlate

            Text(
                "It has no Dock icon and nothing on screen: what it measures is up there, at the right of the menu bar. Click the strip for the detail behind a reading, right-click it for settings and Quit."
            )
            Text(
                "A menu bar that is full has no room to spare, and macOS gives the room it has to whoever asked first — so if the strip is not up there, it was refused a place. Launching Caliper again, from Applications or from Spotlight, brings this window back."
            )
            .foregroundStyle(.secondary)

            box {
                LaunchAtLoginToggle(preferences: preferences)
                Toggle("Show Caliper in the Dock", isOn: $preferences.showsDockIcon)
            }
        }
    }

    /// What the strip will look like where it is going, beside the one thing
    /// every Mac has in that corner.
    private var menuBarPlate: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            MenuBarStripPreview(
                parts: preferences.menuBar,
                combined: preferences.combinesModules,
                coloured: preferences.colouredIndicators,
                metrics: metrics
            )
            // `Text(_:style:)` rather than a formatted string, which is read
            // once and then sits there wrong beside a live strip.
            Text(Date.now, style: .time)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(.unemphasizedSelectedContentBackgroundColor))
        )
        .accessibilityLabel("A preview of the menu bar strip")
    }

    // MARK: - What it shows

    private var strip: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What should it show?")
                .font(.system(size: 22, weight: .semibold))

            menuBarPlate

            VStack(alignment: .leading, spacing: 4) {
                Text(width)
                    .monospacedDigit()
                Text(
                    "Including the padding macOS puts around a menu bar item, which is why sharing one is narrower than taking several. A bar with no room left drops what will not fit, and fewer readings — or a symbol in place of a graph — is the only way to ask for less."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            box {
                Toggle("Combine into one item", isOn: $preferences.combinesModules)
                Text(
                    "One button drawing every reading, and one click that opens all of them. Separate items can be dragged apart with ⌘ held — and are dropped one at a time when the bar runs out."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Or the box hands it one line and an ellipsis: the switch
                // above it has no intrinsic width to speak of, so the box's
                // own is whatever this paragraph claims to want.
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(preferences.menuBar.order, id: \.self) { module in
                    MenuBarModuleRow(preferences: preferences, metrics: metrics, module: module)
                }
            }
        }
    }

    private var width: String {
        let points = StripWidth.points(
            of: preferences.menuBar,
            combined: preferences.combinesModules
        )
        return "This strip takes \(Int(points.rounded())) points of menu bar."
    }

    /// A grouped `Form` would be the native shape of these, and
    /// `ImageRenderer` draws one as an empty rectangle — it scrolls inside.
    private func box(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
        )
        // A dark appearance draws the control background within a shade of the
        // window's own, so the box only has edges if it is given some.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separatorColor))
        )
    }
}
