import SwiftUI

extension Color {
    /// The red the card and its waveform take on while releasing would cancel
    /// the recording.
    ///
    /// Deeper than the system red on purpose: next to the app's orange accent
    /// a bright red is too close a neighbour to read as "let go and nothing is
    /// sent". It stays a shade brighter in the dark appearance, where the fully
    /// darkened red would sink into the glass.
    static let cancel = Color("IntercomCancel")
}
