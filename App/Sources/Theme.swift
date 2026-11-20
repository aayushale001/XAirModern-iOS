import SwiftUI

enum Theme {
    /// X-Air channel colours 0-7 (namecolours table @0x1002d5ad4); 8-15 are the inverted variants.
    static let channelColors: [Color] = [
        Color(red: 0.25, green: 0.25, blue: 0.27),
        Color(hex: 0xE72D2E), Color(hex: 0x35E72D), Color(hex: 0xFCF300),
        Color(hex: 0x0060FF), Color(hex: 0xED27AC), Color(hex: 0x2DE0E7), Color(hex: 0xFFFFFF),
    ]
    static let colorNames = ["Off", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    static func channelColor(_ index: Int) -> Color { channelColors[max(0, index) % 8] }
    static func isInverted(_ index: Int) -> Bool { index >= 8 }
    static func colorName(_ index: Int) -> String { colorNames[max(0, index) % 8] + (index >= 8 ? " (inverted)" : "") }

    static let meterGreen = Color(hex: 0x30D158)
    static let meterYellow = Color(hex: 0xFFD60A)
    static let meterRed = Color(hex: 0xFF453A)
    static let mute = Color(hex: 0xFF453A)
    static let solo = Color(hex: 0xFFD60A)
    static let accent = Color.accentColor
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// Readable text on a channel colour.
extension Color {
    static func onChannel(_ index: Int) -> Color {
        let i = max(0, index) % 8
        return (i == 0 || i == 4 || i == 1 || i == 5) ? .white : .black
    }
}
