import SwiftUI

enum ThemeName: String, CaseIterable, Identifiable {
    case darkMatte, whiteMatte
    var id: String { rawValue }
    var title: String { self == .darkMatte ? "Dark Matte" : "White Matte" }
}

/// Flat, matte colours. No glass, no gradients. The notch band itself is always black.
struct Theme {
    let background: Color
    let tile: Color
    let text: Color
    let secondary: Color
    let accent: Color
    /// Fill for filled buttons (white text). Dark Matte uses a deeper blue than its accent,
    /// because white on #8FC7FF is pale and hard to read.
    let button: Color

    static func named(_ name: ThemeName) -> Theme {
        switch name {
        case .darkMatte:
            Theme(background: Color(hex: 0x16181F), tile: Color(hex: 0x21242D),
                  text: Color(hex: 0xE3E7EF), secondary: Color(hex: 0xA4ABBA), accent: Color(hex: 0x8FC7FF), button: Color(hex: 0x2F6DB0))
        case .whiteMatte:
            Theme(background: Color(hex: 0xF7F8FA), tile: Color(hex: 0xFBFBFC),
                  text: Color(hex: 0x1E2129), secondary: Color(hex: 0x545A69), accent: Color(hex: 0x3B82D0), button: Color(hex: 0x3B82D0))
        }
    }

    /// Content drawn on the black band (compact pill) always uses light colours.
    static let bandText = Color(hex: 0xE3E7EF)
    static let bandSecondary = Color(hex: 0xA4ABBA)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
