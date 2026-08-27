import AppKit
import SwiftUI

/// The third-party notices, read out of the bundle.
///
/// GRDB is linked into the executable and Sparkle rides along as a framework.
/// Both are MIT, and MIT grants everything it grants on one condition — that
/// the notice travels with the copy. A `NOTICE` file in the repository settles
/// that for someone reading the source and for nobody who downloaded a disk
/// image, so the same file is bundled as a resource and this is what reads it.
enum Acknowledgements {
    /// The bundled `NOTICE`, or `nil` when the build did not carry one.
    ///
    /// Read when the sheet opens rather than held in memory: it is a couple of
    /// kilobytes nobody looks at twice, and the menu-bar steady state is the
    /// budget it would otherwise come out of.
    static func text() -> String? {
        // No extension — the file is `NOTICE`, the name the convention uses.
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// What a build that lost the resource shows instead.
    ///
    /// Naming the two libraries and pointing at the file that is certainly
    /// there, rather than an empty pane that reads as "nothing is owed to
    /// anyone". `Scripts/smoke_test.sh` fails on the missing resource, because
    /// a fallback this graceful is exactly what would let it ship unnoticed.
    static let fallback = """
        The bundled NOTICE could not be read, which is a defect in this build \
        rather than an absence of anything to acknowledge.

        Caliper is MIT-licensed and ships GRDB.swift (Copyright © 2015-2025 \
        Gwendal Roué) and Sparkle (Copyright © 2006-2013 Andy Matuschak and \
        others), both under the MIT licence. The full notice is at
        https://github.com/olegklimakov/caliper/blob/main/NOTICE
        """
}

/// The notices as a sheet on the settings room.
///
/// A sheet rather than a window: the settings are already a room of the history
/// window, and a legal notice read once does not want a window controller, a
/// position to restore or a slot in the Window menu.
struct AcknowledgementsSheet: View {
    let dismiss: () -> Void
    @State private var text: String?

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
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 620, height: 460)
        .onAppear { text = Acknowledgements.text() }
    }
}

/// The notice itself: a scrolling, selectable, monospaced document.
///
/// AppKit rather than `ScrollView { Text(…) }`, which looks like the same thing
/// and is not. Two thirds of this notice sit below the fold, and in the SwiftUI
/// stack the page and arrow keys move none of it — focus reaches the scroll
/// view and nothing in it implements scrolling by key, so the document was
/// reachable by trackpad alone. Driving the real app is what showed it: the
/// scroll bar's value indicator stayed at 0 through every Page Down. An
/// `NSTextView` in an `NSScrollView` is what a scrolling document *is* on this
/// platform, and it arrives with selection, keyboard navigation and the text
/// system's own accessibility rather than needing each one added back.
private struct NoticeText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // Monospaced because the file is laid out in columns and rules that only
        // line up in a fixed pitch. Eleven points keeps the eighty-column rules
        // inside the sheet's width, so nothing that is meant to be a straight
        // line wraps into two.
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only when it actually differs: assigning `string` rebuilds the layout
        // and sends the reader back to the top, and this view is updated
        // whenever the sheet is.
        guard textView.string != text else { return }
        textView.string = text
    }
}
