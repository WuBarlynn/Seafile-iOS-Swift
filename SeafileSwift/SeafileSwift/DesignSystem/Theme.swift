import SwiftUI

extension Color {
    static let seafileOrange = Color(red: 236 / 255, green: 114 / 255, blue: 31 / 255)
    static let seafileAmber = Color(red: 255 / 255, green: 176 / 255, blue: 88 / 255)
    static let seafileCoral = Color(red: 255 / 255, green: 122 / 255, blue: 89 / 255)

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red, green, blue, alpha: UInt64
        switch cleaned.count {
        case 8:
            red = (value >> 24) & 0xFF
            green = (value >> 16) & 0xFF
            blue = (value >> 8) & 0xFF
            alpha = value & 0xFF
        case 6:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
            alpha = 255
        default:
            red = 128; green = 128; blue = 128; alpha = 255
        }
        self.init(.sRGB,
                  red: Double(red) / 255,
                  green: Double(green) / 255,
                  blue: Double(blue) / 255,
                  opacity: Double(alpha) / 255)
    }
}

struct SeafileBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: colors)
            RadialGradient(colors: [Color.seafileOrange.opacity(colorScheme == .dark ? 0.22 : 0.16), .clear],
                           center: .topTrailing,
                           startRadius: 10,
                           endRadius: 520)
            RadialGradient(colors: [Color(hex: "#5B8DEF").opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                           center: .bottomLeading,
                           startRadius: 10,
                           endRadius: 560)
        }
        .ignoresSafeArea()
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            return [
                Color(hex: "#111214"), Color(hex: "#141518"), Color(hex: "#17181C"),
                Color(hex: "#141519"), Color(hex: "#1B1C21"), Color(hex: "#191A20"),
                Color(hex: "#101114"), Color(hex: "#15161B"), Color(hex: "#121317")
            ]
        }
        return [
            Color(hex: "#FFF9F3"), Color(hex: "#FDF4EC"), Color(hex: "#F7F1EC"),
            Color(hex: "#FBF3EC"), Color(hex: "#F3F2F7"), Color(hex: "#EEF2FA"),
            Color(hex: "#F8F4F0"), Color(hex: "#F1F3F9"), Color(hex: "#F7F8FC")
        ]
    }
}

struct SeafileSymbol: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color.seafileAmber, Color.seafileOrange, Color.seafileCoral],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            Image(systemName: "cloud.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: 2)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.seafileOrange.opacity(0.3), radius: size * 0.2, y: size * 0.08)
    }
}

struct BrandHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            SeafileSymbol(size: 76)
            Text("Seafile")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Your files, everywhere.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
