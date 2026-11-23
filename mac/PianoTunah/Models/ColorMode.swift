import AppKit
import SwiftUI

/// The color mode in Settings: follow macOS, or always light or dark.
enum ColorMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    /// The key in UserDefaults (@AppStorage).
    static let storageKey = "colorMode"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Sets the appearance of the whole app.
    @MainActor func apply() {
        NSApp?.appearance = switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
