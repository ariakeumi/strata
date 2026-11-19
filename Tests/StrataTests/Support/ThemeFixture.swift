@testable import StrataTheme

// Tint inputs for rendering and native-material restoration tests.
extension ColorTheme {
    nonisolated static let graphite = ColorTheme.tinted(ThemeRGB(red: 0.39, green: 0.39, blue: 0.39))
    nonisolated static let blue = ColorTheme.tinted(ThemeRGB(red: 0.38, green: 0.44, blue: 0.67))
    nonisolated static let green = ColorTheme.tinted(ThemeRGB(red: 0.46, green: 0.65, blue: 0.32))
    nonisolated static let purple = ColorTheme.tinted(ThemeRGB(red: 0.50, green: 0.33, blue: 0.67))
    nonisolated static let sand = ColorTheme.tinted(ThemeRGB(red: 0.69, green: 0.43, blue: 0.19))
    nonisolated static let teal = ColorTheme.tinted(ThemeRGB(red: 0.28, green: 0.52, blue: 0.54))
    nonisolated static let rose = ColorTheme.tinted(ThemeRGB(red: 0.74, green: 0.34, blue: 0.37))
    nonisolated static let amber = ColorTheme.tinted(ThemeRGB(red: 0.72, green: 0.56, blue: 0.16))

    nonisolated static let allCases: [ColorTheme] = [.system, .graphite, .blue, .green, .purple, .sand, .teal, .rose, .amber]
}
