import SwiftUI

/// Omarchy-style swappable themes.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background, surface, raised, border, text, muted, accent, grid: Color
    /// Text colour on stickies.
    let ink: Color
    /// yellow, orange, pink, purple, blue, green
    let palette: [Color]

    init(_ id: String, _ name: String, dark: Bool, bg: String, surface: String, raised: String,
         border: String, text: String, muted: String, accent: String, grid: String, ink: String,
         palette: [String]) {
        self.id = id
        self.name = name
        self.isDark = dark
        self.background = Color(hex: bg)
        self.surface = Color(hex: surface)
        self.raised = Color(hex: raised)
        self.border = Color(hex: border)
        self.text = Color(hex: text)
        self.muted = Color(hex: muted)
        self.accent = Color(hex: accent)
        self.grid = Color(hex: grid)
        self.ink = Color(hex: ink)
        self.palette = palette.map { Color(hex: $0) }
    }

    func color(_ c: CardColor) -> Color {
        switch c {
        case .none: raised
        case .yellow: palette[0]
        case .orange: palette[1]
        case .pink: palette[2]
        case .purple: palette[3]
        case .blue: palette[4]
        case .green: palette[5]
        }
    }

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

    static let all: [Theme] = [
        Theme("tokyo-night", "Tokyo Night", dark: true,
              bg: "1a1b26", surface: "24283b", raised: "292e42", border: "3b4261",
              text: "c0caf5", muted: "7a82b0", accent: "7aa2f7", grid: "2f3549", ink: "1a1b26",
              palette: ["e0af68", "ff9e64", "f7768e", "bb9af7", "7aa2f7", "9ece6a"]),
        Theme("catppuccin", "Catppuccin", dark: true,
              bg: "1e1e2e", surface: "313244", raised: "45475a", border: "585b70",
              text: "cdd6f4", muted: "9399b2", accent: "cba6f7", grid: "313244", ink: "1e1e2e",
              palette: ["f9e2af", "fab387", "f38ba8", "cba6f7", "89b4fa", "a6e3a1"]),
        Theme("gruvbox", "Gruvbox", dark: true,
              bg: "282828", surface: "3c3836", raised: "504945", border: "665c54",
              text: "ebdbb2", muted: "a89984", accent: "fabd2f", grid: "3c3836", ink: "282828",
              palette: ["fabd2f", "fe8019", "fb4934", "d3869b", "83a598", "b8bb26"]),
        Theme("everforest", "Everforest", dark: true,
              bg: "2d353b", surface: "343f44", raised: "3d484d", border: "4f585e",
              text: "d3c6aa", muted: "9da9a0", accent: "a7c080", grid: "3d484d", ink: "2d353b",
              palette: ["dbbc7f", "e69875", "e67e80", "d699b6", "7fbbb3", "a7c080"]),
        Theme("rose-pine-dawn", "Rosé Pine Dawn", dark: false,
              bg: "faf4ed", surface: "fffaf3", raised: "f2e9e1", border: "dfdad9",
              text: "575279", muted: "9893a5", accent: "907aa9", grid: "e4dcd3", ink: "575279",
              palette: ["f6d9a0", "f4c3a1", "f0c3c6", "ddd0ec", "c3dbe0", "cfe3cf"]),
        Theme("paper", "Paper", dark: false,
              bg: "f4f4ef", surface: "ffffff", raised: "efefea", border: "dcdcd5",
              text: "1f1f1f", muted: "7a7a7a", accent: "2f6fed", grid: "dcdcd5", ink: "1f1f1f",
              palette: ["fff1a8", "ffd8b0", "ffc9d6", "e2d6ff", "cfe4ff", "d4f2cc"]),
    ]
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.all[0]
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}
