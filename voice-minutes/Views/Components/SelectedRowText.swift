import SwiftUI

/// Text color for content sitting on a list's own selection highlight.
///
/// `alternateSelectedControlTextColor` is the system color Apple defines for
/// "the text on a selected surface in a list or table", so it follows the
/// accent color, the appearance, and the increased-contrast setting instead of
/// assuming the highlight is always the default blue.
enum SelectedRowText {
    static var color: Color {
        #if os(macOS)
        Color(nsColor: .alternateSelectedControlTextColor)
        #else
        // UIKit already switches row content to the selected text color.
        Color.primary
        #endif
    }
}
