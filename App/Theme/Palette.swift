import AppKit

/// Colour tokens from `Caliper.pen`.
///
/// Every token carries both appearances, because the light values are not
/// tints of the dark ones — the accents are darkened variants chosen to hold
/// at least 3:1 against light surfaces. `NSColor(name:dynamicProvider:)` picks
/// per appearance at draw time, so a redraw after a theme switch is enough.
///
/// Surfaces deliberately stop at the panel: popovers use the system `.popover`
/// material and semantic label colours, which is what gives vibrancy and free
/// support for Increase Contrast and Reduce Transparency.
enum Palette {
    // Metric accents.
    static let cpu = dynamic(dark: 0x0A_84FF, light: 0x00_7AFF)
    static let cpuEfficiency = dynamic(dark: 0x64_D2FF, light: 0x32_ADE6)
    static let memory = dynamic(dark: 0xBF_5AF2, light: 0xAF_52DE)
    static let disk = dynamic(dark: 0xFF_9F0A, light: 0xE8_890C)
    static let networkDown = dynamic(dark: 0x32_D74B, light: 0x24_8A3D)
    static let networkUp = dynamic(dark: 0x0A_84FF, light: 0x00_7AFF)
    /// Temperature draws neutral: red is reserved for danger, and a warm line
    /// on a temperature chart reads as a warning that isn't there.
    static let temperature = dynamic(dark: 0xA0_A0A8, light: 0x6E_6E73)

    // Severity. Single-purpose: red means critical and nothing else.
    static let ok = dynamic(dark: 0x32_D74B, light: 0x24_8A3D)
    static let warning = dynamic(dark: 0xFF_D60A, light: 0xC9_7A00)
    static let critical = dynamic(dark: 0xFF_453A, light: 0xD7_0015)

    // Chart furniture.
    static let gridLine = dynamic(dark: 0xFF_FFFF, light: 0x00_0000, darkAlpha: 0.05, lightAlpha: 0.08)
    /// The unfilled part of a ring or bar, so a value of zero still shows the
    /// shape it is a fraction of.
    static let track = dynamic(dark: 0xFF_FFFF, light: 0x00_0000, darkAlpha: 0.08, lightAlpha: 0.08)

    private static func dynamic(
        dark: Int,
        light: Int,
        darkAlpha: CGFloat = 1,
        lightAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(
                hex: isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }
}

extension NSColor {
    fileprivate convenience init(hex: Int, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}
