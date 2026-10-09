import SwiftUI

/// The colour field behind the intercom grid.
///
/// Liquid Glass refracts whatever is behind it; over a flat system colour it
/// reads as a plain grey card. A slow gradient gives the cards something to
/// bend, and stays quiet enough not to compete with them.
///
/// home-intercom's "Aurora" field, fixed: the picker for the other styles did
/// not come along.
struct Backdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Aurora leads on its own blue rather than the accent: the accent is
    /// orange, and orange between teal and indigo turns the field muddy.
    private static let lead = Color.blue
    private static let cool = Color.teal
    private static let warm = Color.indigo

    var body: some View {
        ZStack {
            Color(.systemBackground)
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.4, 0.55], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
                ],
                colors: colors
            )
            .opacity(colorScheme == .dark ? 0.55 : 0.75)
        }
        .ignoresSafeArea()
    }

    /// The lead hue fanned out into its cooler and warmer neighbours, faded
    /// towards the system background so the field never gets loud.
    private var colors: [Color] {
        let base = Color(.systemBackground)
        return [
            Self.lead.mix(with: base, by: 0.25), Self.cool.mix(with: base, by: 0.55), base,
            Self.warm.mix(with: base, by: 0.6), base, Self.cool.mix(with: base, by: 0.7),
            base, Self.lead.mix(with: base, by: 0.7), Self.warm.mix(with: base, by: 0.5),
        ]
    }
}

#Preview {
    Backdrop()
}
