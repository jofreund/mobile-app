import SwiftUI

/// Reports its pressed state instead of restyling the label.
///
/// `List` gives a `NavigationLink` row a full-width highlight on press for free. A `Button` row
/// gets nothing comparable: the default style tints the label with the accent colour, which is
/// wrong for a title, and `.plain` — which is what these rows used — removes the tint but leaves
/// only a slight dimming of the text. So tapping a track to play it barely registered, while
/// tapping an album right above it lit up the whole row.
///
/// The highlight itself has to be drawn as a `listRowBackground` rather than inside the button:
/// a background on the label stops at the row's content frame, leaving the list's own leading and
/// trailing insets uncoloured, which reads as a floating rectangle rather than a selected row.
/// This style therefore only carries the state outward; see `View.pressHighlight(_:)`.
struct PressReportingButtonStyle: ButtonStyle {

    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // The whole row, not just the glyphs and text — otherwise a tap in the gap between
            // artwork and title does nothing at all.
            .contentShape(.rect)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

extension View {
    /// Paints the row while it is pressed, matching what `List` does for its navigating rows.
    ///
    /// Apply to the row's outermost view. `listRowBackground` is collected per row, so putting it
    /// on the row root is what makes it span the full width including the insets.
    ///
    /// - Parameter isPressed: state owned by the row, fed by `PressReportingButtonStyle`.
    func pressHighlight(_ isPressed: Bool) -> some View {
        // `systemGray4` is the shade UIKit has long used for a selected table row, and it tracks
        // light and dark. There is no API for the exact colour `List` paints its own rows with,
        // so a row that plays and a row that navigates are matched by eye rather than by token.
        listRowBackground(isPressed ? Color(uiColor: .systemGray4) : nil)
    }
}
