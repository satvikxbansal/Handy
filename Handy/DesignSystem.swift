import SwiftUI

enum DS {
    private static var isLight: Bool { AppSettings.shared.isLightMode }

    // MARK: - Colors (Theme-aware: dark default, optional light)
    enum Colors {
        static var background: Color { isLight ? Color(hex: "FFFFFF") : Color(hex: "0D0D0D") }
        static var surface: Color { isLight ? Color(hex: "F5F5F7") : Color(hex: "1A1A1A") }
        static var surfaceElevated: Color { isLight ? Color(hex: "EAEAEC") : Color(hex: "252525") }
        static var surfaceHover: Color { isLight ? Color(hex: "E0E0E2") : Color(hex: "2A2A2A") }
        static var border: Color { isLight ? Color(hex: "D1D1D6") : Color(hex: "333333") }
        static var borderSubtle: Color { isLight ? Color(hex: "E5E5EA") : Color(hex: "262626") }

        static var textPrimary: Color { isLight ? Color(hex: "1D1D1F") : Color(hex: "F5F5F5") }
        static var textSecondary: Color { isLight ? Color(hex: "6E6E73") : Color(hex: "A3A3A3") }
        static var textTertiary: Color { isLight ? Color(hex: "8E8E93") : Color(hex: "737373") }
        static var textMuted: Color { isLight ? Color(hex: "AEAEB2") : Color(hex: "525252") }

        static var accent: Color { Color(hex: "3B82F6") }
        static var accentHover: Color { Color(hex: "2563EB") }
        static var accentSubtle: Color { isLight ? Color(hex: "DBEAFE") : Color(hex: "1E3A5F") }

        static var success: Color { Color(hex: "22C55E") }
        static var warning: Color { Color(hex: "F59E0B") }
        static var error: Color { Color(hex: "EF4444") }
        static var errorSubtle: Color { isLight ? Color(hex: "FEE2E2") : Color(hex: "3B1111") }

        static var userBubble: Color { isLight ? Color(hex: "DBEAFE") : Color(hex: "1E3A5F") }
        static var assistantBubble: Color { isLight ? Color(hex: "F5F5F7") : Color(hex: "1F1F1F") }

        static let cursorBlue = Color(hex: "3B82F6")
        static let overlayCursorBlue = Color(hex: "3380FF")

        static let overlayTranscriptBubble = Color(hex: "CA8A04")
        static let overlayResponseBubble = Color(hex: "16A34A")

        static var floatingWidgetOutline: Color { Color(hex: "F59E0B").opacity(0.55) }
        static var floatingWidgetFill: Color { isLight ? Color(hex: "FFFFFF") : Color(hex: "1A1A1A") }

        static var webSearchAccent: Color { Color(hex: "14B8A6") }
        static var webSearchAccentSubtle: Color { isLight ? Color(hex: "CCFBF1") : Color(hex: "0F3D38") }
    }

    // MARK: - Typography (SF Pro - system default)
    enum Typography {
        static let titleLarge = Font.system(size: 18, weight: .semibold, design: .default)
        static let titleMedium = Font.system(size: 15, weight: .semibold, design: .default)
        static let titleSmall = Font.system(size: 13, weight: .medium, design: .default)
        static let body = Font.system(size: 13, weight: .regular, design: .default)
        static let bodySmall = Font.system(size: 12, weight: .regular, design: .default)
        static let caption = Font.system(size: 11, weight: .regular, design: .default)
        static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Corner Radius
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
        static let full: CGFloat = 9999
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
