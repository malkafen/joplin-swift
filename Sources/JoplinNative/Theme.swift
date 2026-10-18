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

/// Surfaces of the black theme: a pure black backdrop with dark grey panels floating on it, separated by black
/// gutters, so the sidebar, the note list and the editor read as distinct blocks.
enum Palette {
    static let base = Color(nsColor: Palette.baseNS)
    static let panel = Color(nsColor: Palette.panelNS)
    static let elevated = Color(nsColor: Palette.elevatedNS)

    static let baseNS = NSColor.black
    static let panelNS = NSColor(srgbRed: 0.094, green: 0.094, blue: 0.094, alpha: 1)
    static let elevatedNS = NSColor(srgbRed: 0.137, green: 0.137, blue: 0.137, alpha: 1)

    /// Width of the black gutter between panels.
    static let gap: CGFloat = 8
    static let radius: CGFloat = 10
}

extension View {
    /// In the black theme, draws the view as a rounded grey panel on the black backdrop. `outer` are the window
    /// edges this column touches: they get a full gutter, inner edges half a gutter so neighbours add up to one.
    func panel(_ theme: AppTheme, outer: Edge.Set = []) -> some View {
        modifier(PanelModifier(enabled: theme == .black, outer: outer))
    }
}

private struct PanelModifier: ViewModifier {
    let enabled: Bool
    let outer: Edge.Set

    func body(content: Content) -> some View {
        if enabled {
            content
                .scrollContentBackground(.hidden)
                .background(Palette.panel, in: shape)
                .clipShape(shape)
                .padding(.leading, inset(.leading))
                .padding(.trailing, inset(.trailing))
                .padding(.bottom, inset(.bottom))
                .background(Palette.base)
        } else {
            content
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }

    private func inset(_ edge: Edge.Set) -> CGFloat {
        outer.contains(edge) ? Palette.gap : Palette.gap / 2
    }
}
