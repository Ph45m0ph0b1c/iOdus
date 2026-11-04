import SwiftUI

/// Colors and sizes for the dashboard look. Values are for a 1920x1080 frame;
/// views scale them with `Theme.scale(for:)`.
enum Theme {
    static let accent = Color(red: 0.063, green: 0.486, blue: 0.063)      // #107C10
    static let accentBright = Color(red: 0.235, green: 0.741, blue: 0.231) // focus glow
    static let background = Color(red: 0.055, green: 0.059, blue: 0.067)
    static let tile = Color(white: 0.15)
    static let tileFocused = Color(white: 0.22)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.70)
    static let focusRing = Color.white

    static let cornerRadius: CGFloat = 6
    static let sidePadding: CGFloat = 96

    // Face button colors for the hint bar.
    static let buttonA = Color(red: 0.42, green: 0.75, blue: 0.27)
    static let buttonB = Color(red: 0.89, green: 0.23, blue: 0.20)
    static let buttonX = Color(red: 0.16, green: 0.49, blue: 0.89)
    static let buttonY = Color(red: 0.98, green: 0.74, blue: 0.13)

    /// The scale for a window size, so that the layout keeps its proportions.
    static func scale(for size: CGSize) -> CGFloat {
        max(0.5, min(size.width / 1920, size.height / 1080))
    }
}
