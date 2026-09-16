import Foundation

enum AppInfo {
    /// For the places macOS reserves for the app's name — About, Hide, Quit,
    /// the window title — and not for the prose elsewhere, which is about the
    /// product rather than the bundle. The development build is "Caliper Dev";
    /// see `project.yml`.
    static let name =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Caliper"
}
