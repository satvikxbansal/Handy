import SwiftUI

enum DS {
    // MARK: - Colors (Dark mode only)
    enum Colors {
        static let background = Color(hex: "0D0D0D")
        static let surface = Color(hex: "1A1A1A")
        static let surfaceElevated = Color(hex: "252525")
        static let surfaceHover = Color(hex: "2A2A2A")
        static let border = Color(hex: "333333")
        static let borderSubtle = Color(hex: "262626")

        static let textPrimary = Color(hex: "F5F5F5")
        static let textSecondary = Color(hex: "A3A3A3")
        static let textTertiary = Color(hex: "737373")
        static let textMuted = Color(hex: "525252")

        static let accent = Color(hex: "3B82F6")
        static let accentHover = Color(hex: "2563EB")
        static let accentSubtle = Color(hex: "1E3A5F")

        static let success = Color(hex: "22C55E")
        static let warning = Color(hex: "F59E0B")
        static let error = Color(hex: "EF4444")
        static let errorSubtle = Color(hex: "3B1111")

        static let userBubble = Color(hex: "1E3A5F")
        static let assistantBubble = Color(hex: "1F1F1F")

        static let cursorBlue = Color(hex: "3B82F6")
        static let overlayCursorBlue = Color(hex: "3380FF")

        static let overlayTranscriptBubble = Color(hex: "CA8A04")
        static let overlayResponseBubble = Color(hex: "16A34A")

        /// Subtle ring around the floating accessory widget (idle); turns white on hover via the view layer.
        static let floatingWidgetOutline = Color(hex: "F59E0B").opacity(0.55)
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
