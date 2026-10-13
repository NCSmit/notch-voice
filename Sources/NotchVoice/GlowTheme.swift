import SwiftUI

enum GlowTheme: String, CaseIterable, Identifiable {
    case aurora, ember, ocean, mint, neon, moonlight

    var id: String { rawValue }

    var name: String {
        switch self {
        case .aurora: "Aurora"
        case .ember: "Ember"
        case .ocean: "Ocean"
        case .mint: "Mint"
        case .neon: "Neon"
        case .moonlight: "Moonlight"
        }
    }

    var colors: [Color] {
        let palette: [UInt32] = switch self {
        case .aurora: [0xFF8F5C, 0xFFC478, 0xFF739E, 0xBD85FF, 0x6BA3FF]
        case .ember: [0xD97757, 0xF2A65A, 0xFFD3A1, 0xE8654A, 0xB5502F]
        case .ocean: [0x2DD4BF, 0x38BDF8, 0x6366F1, 0x22D3EE, 0x3B82F6]
        case .mint: [0x34D399, 0xA3E635, 0x2DD4BF, 0x10B981, 0xBEF264]
        case .neon: [0xFF2BD6, 0x7C3AED, 0x22D3EE, 0xF472B6, 0xA855F7]
        case .moonlight: [0xFFFFFF, 0xCBD5E1, 0x94A3B8, 0xE2E8F0, 0xF8FAFC]
        }
        let colors = palette.map(Color.init(hex:))
        return colors + [colors[0]]
    }

    var accent: LinearGradient {
        let (start, end): (UInt32, UInt32) = switch self {
        case .aurora: (0xFF8F5C, 0xFF739E)
        case .ember: (0xE8654A, 0xF2A65A)
        case .ocean: (0x38BDF8, 0x6366F1)
        case .mint: (0x10B981, 0x34D399)
        case .neon: (0xFF2BD6, 0x7C3AED)
        case .moonlight: (0x94A3B8, 0x64748B)
        }
        return LinearGradient(colors: [Color(hex: start), Color(hex: end)], startPoint: .leading, endPoint: .trailing)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
