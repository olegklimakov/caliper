import Foundation

enum AppInfo {
    /// The bundle's name: "Caliper", or "Caliper Dev" for the development
    /// build, which is a separate app with its own identifier, settings and
    /// history — see `project.yml`.
    ///
    /// For the places macOS reserves for the app's name — About, Hide, Quit,
    /// the window title — and not for the prose elsewhere, which is about the
    /// product rather than the bundle.
    static let name =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Caliper"
}
