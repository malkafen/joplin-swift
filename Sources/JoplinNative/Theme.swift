import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    /// Always dark, with near-black surfaces instead of the system's grey materials.
    case black
    /// Follows the system appearance with standard colours.
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .black: return "Black"
        case .system: return "System"
        }
    }

    var appearance: NSAppearance? {
        self == .black ? NSAppearance(named: .darkAqua) : nil
    }

    var colorScheme: ColorScheme? {
        self == .black ? .dark : nil
    }

    @MainActor
    func apply() {
        NSApp?.appearance = appearance
    }
}

/// Surfaces of the black theme, darkest where the text is read.
enum Palette {
    static let sidebar = Color(nsColor: Palette.sidebarNS)
    static let list = Color(nsColor: Palette.listNS)
    static let editor = Color(nsColor: Palette.editorNS)
    static let bar = Color(nsColor: Palette.barNS)

    static let sidebarNS = NSColor(srgbRed: 0.031, green: 0.031, blue: 0.039, alpha: 1)
    static let listNS = NSColor(srgbRed: 0.047, green: 0.047, blue: 0.059, alpha: 1)
    static let editorNS = NSColor(srgbRed: 0.016, green: 0.016, blue: 0.020, alpha: 1)
    static let barNS = NSColor(srgbRed: 0.024, green: 0.024, blue: 0.031, alpha: 1)
}

extension View {
    /// Replaces the scroll view / material background with a solid colour when the black theme is active.
    func surface(_ color: Color, _ theme: AppTheme) -> some View {
        modifier(SurfaceModifier(color: color, enabled: theme == .black))
    }
}

private struct SurfaceModifier: ViewModifier {
    let color: Color
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.scrollContentBackground(.hidden).background(color)
        } else {
            content
        }
    }
}
