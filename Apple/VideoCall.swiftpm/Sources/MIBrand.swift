import SwiftUI
import UIKit

enum MIBrand {
    // Same day/night palette as YMODEMUPLOADER/AppSettings.kt.
    static let primary = adaptive(0x001D5F, 0x9CBCFF)
    static let secondary = adaptive(0xFF6600, 0xFFAB70)
    static let background = adaptive(0xF2F3F5, 0x08111F)
    static let surface = adaptive(0xFFFFFF, 0x111D2E)
    static let good = adaptive(0x2E7D32, 0x65D487)
    static let warning = adaptive(0xB3261E, 0xFF8A80)
    static let text = primary
    static let onPrimary = adaptive(0xFFFFFF, 0x08111F)
    static let stageBackground = color(0x08111F)
    static let stageAccent = color(0xFFAB70)
    static let stageGood = color(0x65D487)
    private static func color(_ hex: UInt32) -> Color { Color(uiColor: ui(hex)) }
    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in ui(traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

struct MIBrandLogo: View {
    var height: CGFloat = 100
    var body: some View {
        Image("MIBrand", bundle: AppResources.bundle).resizable().scaledToFit()
            .frame(maxWidth: 460).frame(height: height).accessibilityLabel("Monitoreo Inteligente")
    }
}
