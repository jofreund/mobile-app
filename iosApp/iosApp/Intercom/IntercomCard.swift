import Foundation
import SwiftUI

/// One press-and-hold tile — home-intercom's `RoomCard`, with a player in
/// place of a room.
///
/// The gesture is a zero-distance `DragGesture`, not `LongPressGesture`: a long
/// press only fires after its minimum duration, which is far too late for
/// push-to-talk. The same gesture carries slide-to-cancel: while the tile is
/// held it is shown enlarged in a pop-over (see `IntercomView`), and dragging the
/// finger out of that pop-over before releasing discards the recording instead
/// of announcing it.
struct IntercomCard: View {
    let target: IntercomTarget
    let state: IntercomViewModel.CardState
    let isEnabled: Bool
    /// The server takes spoken announcements at all. `isEnabled` is also false
    /// while another card is being held; only this one makes the card say it
    /// cannot be used.
    let isAvailable: Bool
    /// Drawn at pop-over size — bigger type and padding, same content.
    let isExpanded: Bool
    /// The live meter behind the waveform the pop-over shows while recording.
    /// Handed over as the recorder itself, not as a level: passing a value
    /// that changes 25 times a second would redraw the whole card — glass and
    /// all — just as often. Nil for the tiles in the grid, which show none.
    let recorder: IntercomRecorder?
    /// Whether the tile draws its own glass. The pop-over turns this off and
    /// puts one glass under both of its renderings.
    let showsGlass: Bool
    /// Where the finger may go without cancelling, in global coordinates: a
    /// pop-over-sized area around the tile. `nil` while there is no pop-over,
    /// in which case dragging far enough off the tile cancels.
    let cancelOutside: CGRect?
    /// Receives the tile's frame in global coordinates so the pop-over can grow
    /// out of it. Global, not a named space: a named space resolves against a
    /// different origin inside the navigation stack than in its overlay.
    let onPressBegan: (CGRect) -> Void
    /// How far the finger has travelled since it landed, reported on every
    /// move once the press is committed, so the pop-over can follow it.
    let onPressMoved: (CGSize) -> Void
    let onPressEnded: () -> Void
    let onPressCancelled: () -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void

    /// True while the finger is somewhere that would cancel on release. Owned
    /// by the parent so the pop-over copy of the tile shows it too.
    ///
    /// The tiles in the grid are handed a write-only binding — they set it and
    /// read back `false` — because a held tile is invisible under its own
    /// pop-over and has nothing to show. Only the pop-over copies read the
    /// real value. See `IntercomView.writeOnly(_:)`.
    @Binding var willCancel: Bool

    /// What the press callbacks read and write. Deliberately a reference and
    /// not `@State`: the callbacks are captured when the view renders, and a
    /// tap short enough to end before the next render would otherwise see a
    /// stale "no press in progress" and leave the card stuck.
    @State private var press = PressState()

    /// Bookkeeping for one press. Touched only from the main thread, where
    /// the gesture callbacks arrive.
    private final class PressState {
        var isActive = false
        /// Where the finger landed, in the tile's coordinates — the reference
        /// for slide-to-cancel while there is no pop-over to leave.
        var origin: CGPoint = .zero
        var willCancel = false
        /// The tile's frame in global coordinates, kept current by
        /// ``onGeometryChange``.
        ///
        /// Here rather than in `@State` for the same reason as the rest of
        /// this box, and for one more: a global frame changes on *every*
        /// frame the grid scrolls, and holding it in `@State` redrew every
        /// tile on screen — glass, text and all — sixty times a second for
        /// the length of a scroll. Nothing drawn depends on it; only the
        /// press callbacks read it.
        var frame: CGRect = .zero
    }

    /// Without a pop-over: how far the finger has to travel before the press
    /// turns into a cancel.
    private static let cancelDistance: CGFloat = 64

    /// How far the finger may travel before the press is committed without
    /// it counting as a scroll. The press begins in the touch-down, so every
    /// attempt to scroll the grid starts as a press on whatever tile the
    /// finger landed on; past this much travel the tile gives the touch up and
    /// lets the scroll view have it.
    private static let scrollSlop: CGFloat = 10

    init(
        target: IntercomTarget,
        state: IntercomViewModel.CardState,
        isEnabled: Bool,
        isAvailable: Bool = true,
        isExpanded: Bool = false,
        recorder: IntercomRecorder? = nil,
        showsGlass: Bool = true,
        willCancel: Binding<Bool> = .constant(false),
        cancelOutside: CGRect? = nil,
        onPressBegan: @escaping (CGRect) -> Void,
        onPressMoved: @escaping (CGSize) -> Void = { _ in },
        onPressEnded: @escaping () -> Void,
        onPressCancelled: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onDiscard: @escaping () -> Void = {}
    ) {
        self.target = target
        self.state = state
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
        self.isExpanded = isExpanded
        self.recorder = recorder
        self.showsGlass = showsGlass
        self._willCancel = willCancel
        self.cancelOutside = cancelOutside
        self.onPressBegan = onPressBegan
        self.onPressMoved = onPressMoved
        self.onPressEnded = onPressEnded
        self.onPressCancelled = onPressCancelled
        self.onRetry = onRetry
        self.onDiscard = onDiscard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            // An idle player is the normal case and stays quiet; the status
            // row only appears while an announcement is already playing on it.
            if showsStatus {
                HStack(spacing: metrics.spacing * 0.75) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: metrics.statusDot, height: metrics.statusDot)
                    Text("intercom_status_announcing")
                        .font(metrics.status)
                        .foregroundStyle(.secondary)
                }
            }

            // The player's icon shares the name's line rather than claiming a
            // row of its own, at the top so a name that wraps doesn't drag it
            // down.
            HStack(alignment: .top, spacing: metrics.spacing * 0.75) {
                Text(target.name)
                    .font(metrics.name)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                // Exactly twice the tile's size in the pop-over, like the
                // type around it — see `Metrics`.
                PlayerIcon(target.iconId, size: isExpanded ? 36 : 18, relativeTo: .headline)
                    .foregroundStyle(.secondary)
            }

            if let detail {
                Text(detail)
                    .font(metrics.detail)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
            }

            // Centred between the name and the action row: while the pop-over
            // is up, what the microphone hears is the thing worth looking at.
            if showsWaveform {
                Spacer(minLength: 0)
                RecordingWaveform(
                    recorder: recorder,
                    isRecording: state == .recording,
                    isCancelling: willCancel,
                    isExpanded: isExpanded
                )
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            if offersRetry {
                retryControls
            } else {
                HStack(spacing: metrics.spacing) {
                    // No symbol while recording: the waveform above already
                    // says that the microphone is live, and only "Abbrechen"
                    // has anything left to add. Without a symbol beside it
                    // that label is a caption under the waveform rather than
                    // a heading, so it sits smaller and centred on the card.
                    if let symbolName {
                        Image(systemName: symbolName)
                            .font(metrics.symbol)
                    }
                    if centersAction { Spacer(minLength: 0) }
                    if let actionLabel {
                        Text(actionLabel)
                            .font(centersAction ? metrics.recordingAction : metrics.action)
                    }
                    Spacer(minLength: 0)
                    if state == .sending {
                        ProgressView().controlSize(isExpanded ? .large : .small)
                    }
                }
                .foregroundStyle(actionColor)
                // What the row says changes without animating, always: the
                // row is invisible whenever the text and the symbol swap, and
                // an inherited animation would cross-fade the old wording
                // back in over the new one as the row returns.
                .transaction { $0.animation = nil }
                // Only the pop-over card ever takes its row away, and only
                // to bring it back: going is instant — it happens under the
                // opening card, where it is not visible anyway — while
                // "Abbrechen" and "Senden" fade in.
                .opacity(hidesAction ? 0 : 1)
                .animation(hidesAction ? nil : Self.actionFade, value: hidesAction)
            }
        }
        // A tile that cannot be pressed dims its content, not its glass: glass
        // at half opacity turns into a grey smear over the backdrop.
        .opacity(isEnabled || state.isBusy || offersRetry ? 1 : 0.55)
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, minHeight: metrics.minHeight, alignment: .topLeading)
        // Applied to the content itself, not as a background, so the text is
        // drawn above the pane rather than refracted by it.
        .modifier(OptionalGlass(glass: showsGlass ? glass : nil, shape: shape))
        // No press dip: the tile hands straight over to the pop-over growing
        // out of it, and a tile that shrinks a little first only puts a second
        // animation in front of that one.
        .animation(.spring(duration: 0.26, bounce: 0.3), value: willCancel)
        .animation(.spring(duration: 0.3, bounce: 0.32), value: animatedState)
        .contentShape(shape)
        // Not a SwiftUI gesture: inside the grid's scroll view one would be
        // arbitrated before it may begin, and the press has to open the
        // pop-over in the frame the finger lands in. While the card offers
        // "resend", the press is off entirely so its buttons take input.
        .immediatePress(
            isEnabled: !offersRetry,
            onBegan: { location in
                guard isEnabled, !press.isActive else { return }
                press.isActive = true
                press.origin = location
                press.willCancel = false
                willCancel = false
                onPressBegan(press.frame)
            },
            onChanged: { location in
                guard press.isActive else { return }
                // Still inside the arm delay and already travelling: this is
                // the start of a scroll, not a hold. Let go of it entirely —
                // nothing has been claimed, shown or recorded yet, and the
                // scroll view is free to carry the touch on.
                if !isCommitted, travelled(to: location) > Self.scrollSlop {
                    press.isActive = false
                    press.willCancel = false
                    willCancel = false
                    onPressCancelled()
                    return
                }
                // Only once the press is committed — before that the travel
                // belongs to a possible scroll, and the card it would lean is
                // still a tile in the grid.
                if isCommitted {
                    onPressMoved(CGSize(
                        width: location.x - press.origin.x,
                        height: location.y - press.origin.y
                    ))
                }
                let cancels = shouldCancel(at: location)
                guard cancels != press.willCancel else { return }
                press.willCancel = cancels
                willCancel = cancels
            },
            onEnded: { interrupted in
                guard press.isActive else { return }
                press.isActive = false
                let cancelled = interrupted || press.willCancel
                press.willCancel = false
                willCancel = false
                if cancelled {
                    onPressCancelled()
                } else {
                    onPressEnded()
                }
            }
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { press.frame = $0 }
        .accessibilityElement(children: offersRetry ? .contain : .combine)
        .accessibilityLabel(Text(target.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(accessibilityHint))
        .accessibilityAddTraits(.isButton)
        // VoiceOver and Switch Control cannot hold a tile down: the same card
        // works as tap-to-start / tap-to-send for them.
        .accessibilityAction { toggleRecording() }
    }

    /// True once the press has been taken seriously: the card is arming or
    /// recording, or its pop-over is already up. From here the finger is
    /// meant to travel — that is slide-to-cancel — and the grid is locked
    /// anyway.
    private var isCommitted: Bool {
        cancelOutside != nil || state == .arming || state == .recording
    }

    /// How far the finger has come from where it landed, in the tile's own
    /// coordinates.
    private func travelled(to location: CGPoint) -> CGFloat {
        hypot(location.x - press.origin.x, location.y - press.origin.y)
    }

    /// Whether releasing at this point of the press discards the recording.
    /// `location` is in the tile's own coordinates.
    private func shouldCancel(at location: CGPoint) -> Bool {
        if let cancelOutside {
            // The tile is showing as a pop-over: leaving the zone in any
            // direction cancels, coming back sends again. The press reports
            // in the tile's own coordinates, so bring the zone — which is
            // global, like `frame` — into them first.
            let zone = cancelOutside.offsetBy(dx: -press.frame.minX, dy: -press.frame.minY)
            return !zone.contains(location)
        }
        return travelled(to: location) > Self.cancelDistance
    }

    private var retryControls: some View {
        HStack(spacing: 8) {
            Button(action: onRetry) {
                Label("intercom_retry", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(action: onDiscard) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text("intercom_discard"))
        }
    }

    // MARK: - Presentation

    /// Sizes for the tile in the grid and for its pop-over.
    ///
    /// The pop-over is exactly twice the tile in every dimension, type
    /// included: the pop-over copy is shrunk by half onto the tile when it
    /// closes, and anything that is not doubled shows as a jump at the moment
    /// the copy gives way to the tile.
    private struct Metrics {
        let padding: CGFloat
        let spacing: CGFloat
        let cornerRadius: CGFloat
        let statusDot: CGFloat
        let minHeight: CGFloat
        let status: Font
        let name: Font
        let detail: Font
        let symbol: Font
        let action: Font
        let recordingAction: Font

        static let compact = Metrics(
            padding: 14, spacing: 8, cornerRadius: IntercomCard.compactCornerRadius, statusDot: 10, minHeight: 136,
            status: .caption2, name: .headline, detail: .caption,
            symbol: .title3, action: .subheadline.weight(.medium),
            recordingAction: .caption.weight(.medium)
        )
    }

    // Twice the default point size of the tile's text styles, each scaling
    // with Dynamic Type the way its style does, so the ratio holds at every
    // text size.
    @ScaledMetric(relativeTo: .caption2) private var expandedStatusSize: CGFloat = 22
    @ScaledMetric(relativeTo: .headline) private var expandedNameSize: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var expandedDetailSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var expandedSymbolSize: CGFloat = 40
    @ScaledMetric(relativeTo: .subheadline) private var expandedActionSize: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var expandedRecordingActionSize: CGFloat = 24

    /// The tile's and the pop-over's corner radii; `IntercomView` draws the
    /// pop-over's glass in these shapes.
    static let compactCornerRadius: CGFloat = 18
    static let expandedCornerRadius: CGFloat = 36

    private var metrics: Metrics {
        guard isExpanded else { return .compact }
        return Metrics(
            padding: 28, spacing: 16, cornerRadius: Self.expandedCornerRadius, statusDot: 20, minHeight: 272,
            status: .system(size: expandedStatusSize),
            name: .system(size: expandedNameSize, weight: .semibold),
            detail: .system(size: expandedDetailSize),
            symbol: .system(size: expandedSymbolSize),
            action: .system(size: expandedActionSize, weight: .medium),
            recordingAction: .system(size: expandedRecordingActionSize, weight: .medium)
        )
    }

    /// How the action row fades back in. Short: it is a caption changing
    /// under a card that is itself moving.
    private static let actionFade: Animation = .easeInOut(duration: 0.16)

    /// True while there is nothing to say about the recording: the finger is
    /// still inside the card, and the waveform carries that on its own.
    private var withholdsRecordingLabel: Bool {
        (state == .arming || state == .recording) && !willCancel
    }

    /// Only the pop-over card empties its action row. The tile keeps its
    /// microphone under it: the pop-over grows out of the tile and covers it
    /// at once, and the tile-sized copy travelling inside the pop-over
    /// cross-fades away by itself, so the label needs no exit of its own —
    /// one that would have to play out under a card that has already moved
    /// off it.
    private var hidesAction: Bool {
        isExpanded && withholdsRecordingLabel
    }

    /// The state the action row draws: the real one, except on the tile
    /// while there is no recording label, where it stays on the idle
    /// rendering — its microphone, which the tile goes on showing until the
    /// pop-over covers it.
    ///
    /// The pop-over card keeps the recording layout even with its row
    /// hidden, rather than falling back to the idle one: the symbol and the
    /// larger type of the idle rendering are taller, and reserving that
    /// height invisibly and giving it up again the moment "Abbrechen"
    /// appears would shift the waveform above it.
    private var actionState: IntercomViewModel.CardState {
        withholdsRecordingLabel && !isExpanded ? .idle : state
    }

    /// What the card's state animation watches: the real state, except that
    /// arming and recording count as one.
    ///
    /// They draw the same card, so the step between them has nothing to
    /// animate — but it lands in the middle of the pop-over's opening spring,
    /// and a second animation declared over a subtree that is already moving
    /// retargets what is in flight. The card visibly jerked at the moment the
    /// mic came up, for a change that was not there.
    private var animatedState: IntercomViewModel.CardState {
        state == .arming ? .recording : state
    }

    /// While recording, the label is the only thing on the action row, so it
    /// is centred on the card's x axis instead of hugging its leading edge.
    private var centersAction: Bool {
        actionState == .arming || actionState == .recording
    }

    /// The waveform belongs to the pop-over only: a tile in the grid is too
    /// small to show one, and only the held tile has a level to show.
    private var showsWaveform: Bool {
        isExpanded && (state == .recording || state == .arming)
    }

    /// A failed upload whose recording is still on disk.
    private var offersRetry: Bool {
        if case .failed(_, let canRetry) = state { return canRetry }
        return false
    }

    /// The status dot and label are only worth the space while the player is
    /// busy with an announcement — a new one waits for it.
    private var showsStatus: Bool {
        target.isAnnouncing
    }

    private var symbolName: String? {
        switch actionState {
        // A press too short to record leaves the row exactly as it was: just
        // the microphone. Nothing was cancelled, so a cross and "Abgebrochen"
        // would report something that did not happen — and take the row the
        // next press needs away for the length of the linger. The line under
        // the name does the explaining, on its own.
        case .idle, .tooShort: isAvailable ? "mic.fill" : "mic.slash.fill"
        // Arming looks exactly like recording. It is what the card wears
        // from the moment a press is committed — through the pop-over's
        // growth and the frame or two the mic takes behind it — and a symbol
        // and label of its own would only flash past on the way in.
        case .arming, .recording: nil
        case .sending: "arrow.up.circle"
        case .sent: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    /// Nil on a card that is simply waiting to be held: the gesture is spelled
    /// out once above the grid (see ``IntercomView``) instead of on every tile,
    /// where the same word next to a dozen microphones said nothing a single
    /// line could not. A card that cannot take a press still speaks for
    /// itself — that is information about this player, not an instruction.
    private var actionLabel: String? {
        switch actionState {
        case .idle, .tooShort: isAvailable ? nil : String(localized: "intercom_unavailable")
        case .arming, .recording: String(localized: "intercom_action_cancel")
        case .sending: String(localized: "intercom_action_sending")
        case .sent: String(localized: "intercom_action_sent")
        case .cancelled: String(localized: "intercom_action_cancelled")
        case .failed: String(localized: "intercom_action_failed")
        }
    }

    private var detail: String? {
        switch state {
        case .failed(let message, _): message
        case .cancelled(let reason): reason ?? String(localized: "intercom_detail_slid_off")
        case .tooShort: String(localized: "intercom_detail_too_short")
        default: nil
        }
    }

    private var detailColor: Color {
        switch state {
        case .failed: .red
        default: .secondary
        }
    }

    private var actionColor: Color {
        if actionState == .recording || actionState == .arming, willCancel { return .cancel }
        return isEnabled || state.isBusy ? Color.accentColor : Color.secondary
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    private var glass: Glass {
        Self.glass(for: state, isEnabled: isEnabled)
    }

    /// A card's material. Glass draws its own edge and gets no tint while
    /// recording: the pulsing waveform and the red cancel state carry that.
    /// A failed upload gets a faint red tint. Shared with the pop-over pane in
    /// `IntercomView`, which has to match the tile exactly when it hands back.
    ///
    /// `regular`, not `clear`, for both: clear glass reads well on a tile but
    /// left too much of the backdrop in the pop-over's type, and every way of
    /// holding it back had a tell of its own — a scrim behind the pane put the
    /// glass's edge on show as a ring around the card as it opened, and giving
    /// the pane its own denser material made it change materials in the moment
    /// it lands on its tile and hands over.
    static func glass(for state: IntercomViewModel.CardState, isEnabled: Bool) -> Glass {
        var glass: Glass = .regular
        if case .failed = state {
            glass = glass.tint(.red.opacity(0.25))
        }
        if isEnabled {
            glass = glass.interactive()
        }
        return glass
    }

    // MARK: - Accessibility

    private var accessibilityValue: String {
        switch state {
        case .idle: target.isAnnouncing ? String(localized: "intercom_status_announcing") : ""
        case .arming: String(localized: "intercom_a11y_arming")
        case .recording: String(localized: "intercom_a11y_recording")
        case .sending: String(localized: "intercom_a11y_sending")
        case .sent: String(localized: "intercom_action_sent")
        case .cancelled(let reason): reason ?? String(localized: "intercom_action_cancelled")
        case .tooShort: String(localized: "intercom_detail_too_short")
        case .failed(let message, _): message
        }
    }

    private var accessibilityHint: String {
        if offersRetry { return String(localized: "intercom_a11y_hint_retry") }
        if state == .recording || state == .arming { return String(localized: "intercom_a11y_hint_send") }
        guard isEnabled else { return String(localized: "intercom_unavailable") }
        return String(localized: "intercom_a11y_hint_hold")
    }

    /// The accessibility entry point: latching push-to-talk.
    private func toggleRecording() {
        switch state {
        case .arming, .recording:
            onPressEnded()
        // `.tooShort` takes a press like the idle card it is still drawing.
        case .idle, .tooShort:
            guard isEnabled else { return }
            onPressBegan(press.frame)
        default:
            break
        }
    }
}

/// Draws `glass` under the content in `shape`, or leaves the content bare
/// when `glass` is nil.
private struct OptionalGlass: ViewModifier {
    let glass: Glass?
    let shape: RoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        if let glass {
            content.glassEffect(glass, in: shape)
        } else {
            content
        }
    }
}

#Preview {
    let target = IntercomTarget(id: "living", name: "Wohnzimmer", iconId: PlayerIconCatalog.playerDefault, isAnnouncing: false)
    return ScrollView {
        VStack(spacing: 16) {
            IntercomCard(target: target, state: .idle, isEnabled: true, onPressBegan: { _ in }, onPressEnded: {})
            IntercomCard(target: target, state: .recording, isEnabled: true, onPressBegan: { _ in }, onPressEnded: {})
            IntercomCard(
                target: target,
                state: .failed(message: "Keine Verbindung zum Server", canRetry: true),
                isEnabled: false,
                onPressBegan: { _ in },
                onPressEnded: {}
            )
            IntercomCard(
                target: IntercomTarget(id: "kitchen", name: "Küche", iconId: PlayerIconCatalog.playerDefault, isAnnouncing: true),
                state: .idle,
                isEnabled: true,
                onPressBegan: { _ in },
                onPressEnded: {}
            )
            IntercomCard(
                target: target,
                state: .recording,
                isEnabled: true,
                isExpanded: true,
                onPressBegan: { _ in },
                onPressEnded: {}
            )
            IntercomCard(
                target: target,
                state: .recording,
                isEnabled: true,
                isExpanded: true,
                willCancel: .constant(true),
                onPressBegan: { _ in },
                onPressEnded: {}
            )
        }
        .padding()
    }
    .background { Backdrop() }
}
