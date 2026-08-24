import AppKit
import Foundation

// Both of these must answer before AppKit connects to the window server, so the
// binary stays usable from a terminal and from CI.
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains(SelfTestCommand.flag) {
    await SelfTestCommand.run()
}
if let index = arguments.firstIndex(of: UIPreview.flag) {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(
            Data("Caliper: \(UIPreview.flag) needs a directory to write to\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
    await UIPreview.run(writingTo: arguments[index + 1])
}

// AppKit directly, not a SwiftUI `App`. Every window this app has is hosted by
// `AppDelegate` — the panels in popovers and the history window in one of its
// own — because a scene graph can only be opened from inside SwiftUI, and the
// status bar menu that has to open it is AppKit. A scene for the settings is
// what made them unreachable in the first place.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
