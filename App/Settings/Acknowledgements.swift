import AppKit
import SwiftUI

/// The third-party notices, read out of the bundle.
///
/// GRDB is linked into the executable and Sparkle rides along as a framework.
/// Their licences travel with the copy or they are not satisfied, and a file in
/// the repository does not reach anyone who downloaded a disk image — so the
/// same `NOTICE` is bundled as a resource, and this is what reads it back.
enum Acknowledgements {
    /// The bundled `NOTICE`, or `nil` when the build did not carry one.
    ///
    /// Read when the sheet is created rather than held: it is a few kilobytes
    /// nobody looks at twice, and the menu-bar steady state is the budget it
    /// would otherwise come out of.
    static func text() -> String? {
        // No extension — the file is `NOTICE`, the name the convention uses.
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// What a build that lost the resource shows instead.
    ///
    /// It names nothing. Listing the libraries here would be a second copy of
    /// `NOTICE` with nothing keeping it in step, and a stale notice is worse
    /// than an honest pointer to the current one. This text is not the safety
    /// net either — `Scripts/smoke_test.sh` fails on the missing resource,
    /// because a message this graceful is exactly what would let it ship.
    static let fallback = """
        The bundled NOTICE could not be read. That is a defect in this build \
        rather than an absence of anything to acknowledge, and the notice it \
        should have shown is at

        https://github.com/olegklimakov/caliper/blob/main/NOTICE
        """
}

/// The notices as a sheet on the settings room.
///
/// A sheet rather than a window: the settings are already a room of the history
/// window, and a legal notice read once does not want a window controller, a
/// position to restore or a slot in the Window menu.
struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Read once, when the sheet's view value is created. As `onAppear` work it
    /// would draw one frame of the fallback before the real notice replaced it.
    @State private var text = Acknowledgements.text()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Acknowledgements")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            NoticeText(text: text ?? Acknowledgements.fallback)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 620, height: 460)
    }
}

/// The notice itself: a scrolling, selectable, monospaced document.
///
/// AppKit rather than `ScrollView { Text(…) }`, which looks like the same thing
/// and is not. Most of this notice sits below the fold, and in the SwiftUI stack
/// the page and arrow keys move none of it — focus reaches the scroll view and
/// nothing in it implements scrolling by key. Driving the real app is what
/// showed it: the scroll bar's value indicator stayed at 0 through every Page
/// Down, with focus demonstrably inside. An `NSTextView` in an `NSScrollView` is
/// what a scrolling document *is* here, and it arrives with keyboard
/// navigation, selection and the text system's own accessibility rather than
/// needing each one added back.
private struct NoticeText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        // Monospaced because the file is laid out in columns and rules that only
        // line up in a fixed pitch. Eleven points keeps the eighty-column rules
        // inside the sheet's width, so nothing meant to be a straight line wraps.
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text

        // Grow downwards and wrap sideways. Built here rather than taken from
        // `NSTextView.scrollableTextView()`, whose document view comes back as
        // an optional this type would then have to have an opinion about — and
        // the only honest opinion is that it cannot happen.
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Only when it actually differs: assigning `string` rebuilds the layout
        // and sends the reader back to the top, and this view is updated
        // whenever the sheet is.
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text
        else { return }
        textView.string = text
    }
}
