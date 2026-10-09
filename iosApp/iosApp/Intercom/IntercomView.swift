import Foundation
import MusicAssistantKit
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The intercom tab: every player as a card, held to talk — home-intercom's
/// `RoomsView`, with Music Assistant players in place of Home Assistant rooms.
///
/// What fed the room grid — loading, pull-to-refresh, polling, the Home
/// Assistant socket, settings — is gone: the players come from the shell's
/// `PlayerBarStore`, and whether the server takes spoken announcements from
/// `KmpHelper.announcementAvailability`. The press, the pop-over and the send
/// are home-intercom's, unchanged.
///
/// It owns its `NavigationStack` rather than being put in one by `AppTabView`,
/// as `RoomsView` did: the pop-over is an overlay on the stack, so its dim
/// covers the navigation bar too.
struct IntercomView: View {
    let store: PlayerBarStore
    /// Owned by `AppTabView`, like the store: a tab's view is rebuilt every
    /// time the shell's body runs, and this one carries a recorder.
    @Bindable var viewModel: IntercomViewModel

    @State private var availability = IntercomAvailability()

    @Environment(\.scenePhase) private var scenePhase
    /// The tab is on screen. A tab stays alive when another one is chosen, and
    /// the scene-phase handling below must not warm a microphone up for a grid
    /// nobody is looking at.
    @State private var isVisible = false

    /// Where a held tile grows from and to. Set on every press and kept until
    /// the pop-over has slid back onto the tile.
    @State private var expansion: CardExpansion?
    /// Drives the pop-over's geometry: `false` puts the copy exactly over its
    /// tile, `true` at the pop-over spot. Animated in both directions.
    @State private var isPopoverOpen = false
    /// The area the pop-over may occupy, in global coordinates — the one space
    /// the grid's tiles and the overlay agree on.
    @State private var stage: CGRect = .zero
    /// True while the finger is where releasing cancels. Written by the tile
    /// being held, read by its pop-over copies — see ``writeOnly(_:)``.
    @State private var willCancel = false
    /// How far the open pop-over is currently leaning after the finger — a
    /// small shift of the pane and a tilt of its content — see
    /// ``ShiftsWithFinger`` and ``TiltsWithFinger``.
    ///
    /// Deliberately not `@State`: it changes on every touch-move,
    /// and only those two modifiers read it — see there.
    @State private var follow = FingerPull()
    /// The tile the finger is on, from touch-down. The pop-over is built out
    /// of it only once the press has outlasted a tap — long after the tile
    /// reported the frame — so the frame has to be kept until then.
    @State private var pressedTile: PressedTile?
    /// Whether the line above the grid is up. Follows
    /// ``IntercomViewModel/showsHoldHint`` a cycle behind, so that its animation
    /// is the hint's own and nothing else in the grid rides along — see
    /// `grid`.
    @State private var showsHint = false

    private struct PressedTile: Equatable {
        let key: String
        /// The tile's frame in global coordinates.
        let frame: CGRect
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private struct CardExpansion: Equatable {
        /// Distinguishes one press from the next on the same tile, so a copy
        /// that is still sliding back is replaced, not reused.
        let id = UUID()
        let key: String
        /// The tile's frame in the grid — where the pop-over grows from.
        let collapsed: CGRect
        /// The pop-over's frame: twice the tile, centred on it. Also the zone
        /// the finger may stay in without cancelling — it is what is actually
        /// on screen, so the cancel edge sits where the user sees the card.
        let popover: CGRect
    }

    /// Margin between the pop-over and the edge of the screen.
    private static let popoverInset: CGFloat = 16
    /// How far the finger has to travel for the card's lean to be most of the
    /// way to its limit — see ``lean(_:)``.
    private static let leanReach: CGFloat = 90
    /// Growing: a springy pop that overshoots a little before it settles, so
    /// the card feels thrown open rather than resized.
    ///
    /// Interpolating, and launched with real initial velocity: a plain spring
    /// starts from standstill and eases *in*, so for the first few frames the
    /// card sits at its tile size and the press reads as if nothing had
    /// happened yet. The kick puts the movement in the frame the finger lands
    /// in; the bounce is what makes it read as thrown rather than driven.
    private static let expandAnimation: Animation = .interpolatingSpring(
        duration: 0.24,
        bounce: 0.34,
        initialVelocity: 3
    )
    /// Safety net for `expandAnimation`'s completion handler, which SwiftUI
    /// does not guarantee to fire: a state change elsewhere in the tree while
    /// the pop-over is opening — a live status update, another card's reset
    /// timer — can silently drop it, and with nothing to catch that the press
    /// was left stuck on `.arming` forever, with no mic and no haptic ever
    /// firing. Comfortably longer than the bouncy settle `expandAnimation`
    /// actually takes past its nominal 0.24s, so it never wins the race under
    /// normal conditions and only catches a drop. See the `.task` below.
    private static let expandFallbackDelay: Duration = .milliseconds(500)
    /// Shrinking: quicker and only lightly bouncy. The copy has to land back
    /// on its tile and hand over to it, so it settles with less overshoot
    /// than it opened with — a big rebound there reads as a glitch.
    private static let collapseAnimation: Animation = .spring(duration: 0.3, bounce: 0.24)
    /// The dim behind the pop-over: plain easing. A bouncing spring would
    /// brighten the backdrop again half-way through opening.
    private static let dimAnimation: Animation = .easeOut(duration: 0.24)
    /// The cross-fade between the two renderings. Kept on its own short curve
    /// and front-loaded: the swap should be over well before the geometry has
    /// finished bouncing, so no wobble is visible through two half-lit copies.
    private static let crossfadeAnimation: Animation = .easeInOut(duration: 0.16)

    var body: some View {
        NavigationStack {
            ZStack {
                // A sibling of the content, not its `.background`. The Group
                // below switches branches, and a background hanging off it is
                // torn down and rebuilt on every switch — the field then
                // re-renders, and the cards' glass, which samples whatever is
                // behind it, re-refracts with it. Here the gradient outlives
                // the branches.
                //
                // It also cannot go behind the NavigationStack: the stack
                // draws its own opaque background over anything back there.
                Backdrop()

                Group {
                    if availability.serverTooOld {
                        serverTooOld
                    } else if viewModel.targets.isEmpty, !availability.voice {
                        ProgressView("intercom_loading")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .glassEffect()
                    } else if viewModel.targets.isEmpty {
                        noPlayers
                    } else {
                        grid
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Inline title: the bar only needs to name the screen, not claim
            // the large title's extra height.
            .navigationTitle("nav_intercom")
            .navigationBarTitleDisplayMode(.inline)
            .alert("intercom_error_no_microphone", isPresented: $viewModel.showsMicrophonePermissionAlert) {
                Button("intercom_open_settings") { openSystemSettings() }
                Button("intercom_action_cancel", role: .cancel) {}
            } message: {
                Text("intercom_microphone_explanation")
            }
        }
        .overlay { popover }
        .onChange(of: targets, initial: true) { _, targets in
            viewModel.update(targets: targets, isAvailable: availability.voice)
        }
        .onChange(of: availability.voice) { _, voice in
            viewModel.update(targets: targets, isAvailable: voice)
        }
        .onAppear {
            isVisible = true
            availability.start()
            // Warms mic and audio session so the first press records from the
            // first syllable instead of from wherever the session finished
            // activating.
            viewModel.prepareRecorder()
            Haptics.startKeepingWarm()
        }
        // The engine only stays primed for a second or two, and touch-down is
        // already the moment the tap has to play — see
        // ``Haptics/startKeepingWarm()``. Tied to the grid, not to the app.
        .onDisappear {
            isVisible = false
            Haptics.stopKeepingWarm()
            // A second finger on the tab bar can leave the tab with a card
            // still held; nothing may go on recording behind another tab.
            viewModel.cancelActiveRecording(message: String(localized: "intercom_recording_cancelled"))
        }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            switch phase {
            case .active:
                viewModel.prepareRecorder()
                Haptics.startKeepingWarm()
            case .background:
                Haptics.stopKeepingWarm()
                viewModel.cancelActiveRecording(message: String(localized: "intercom_recording_cancelled"))
            default:
                // `.inactive` is a notification banner, Control Centre or the
                // app switcher — none of which should kill a recording that is
                // still being held.
                break
            }
        }
    }

    /// The players as cards: the shell's list, in its order, without the
    /// phone's own player — a spoken announcement to it would be recorded and
    /// played on the same device. Upstream leaves it out the same way.
    private var targets: [IntercomTarget] {
        store.players
            .filter { !$0.isLocal }
            .map { IntercomTarget(id: $0.id, name: $0.name, iconId: $0.iconId, isAnnouncing: $0.isAnnouncing) }
    }

    private var grid: some View {
        ScrollView {
            if showsHint {
                hint
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // No GlassEffectContainer around the tiles: a container renders
            // its glass through a different path than standalone glass, and
            // the pop-over pane in the overlay cannot join it, so the two
            // would differ in edge and shadow at the moment the pane hands
            // back to the tile.
            tiles
                .padding(16)
                // Push-to-talk has to begin on touch-down, not after the
                // scroll view has waited out its delay to see if this is a
                // scroll.
                .immediateTouches()
        }
        // The line slides in and out rather than shoving the grid a frame
        // after the tap. Animated from here, through `showsHint`, and not
        // with `.animation(_:value:)` on the scroll view: the hint goes down
        // in the same breath as the pop-over handing its card back, and a
        // blanket animation on this subtree took the tile's return with it —
        // the tile is drawn at zero opacity while its copy is out (see
        // `tiles`), so it faded back in instead of simply being there. This
        // runs a cycle later, on its own, and only moves the hint and the
        // grid below it.
        .onChange(of: viewModel.showsHoldHint) { _, shows in
            withAnimation(.snappy) { showsHint = shows }
        }
        // Sliding off the pop-over while holding a tile cancels; it must not
        // scroll the grid instead.
        .scrollDisabled(presentedKey != nil)
    }

    private var tiles: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(viewModel.targets) { target in
                IntercomCard(
                    target: target,
                    state: viewModel.state(for: target),
                    isEnabled: viewModel.isPressable(target),
                    isAvailable: viewModel.isAvailable,
                    willCancel: Self.writeOnly($willCancel),
                    cancelOutside: presentedKey == target.id ? expansion?.popover : nil,
                    // Touch-down changes nothing on screen: a press that
                    // turns out to be a tap has to leave the grid exactly as
                    // it found it, so the pop-over waits for the view model
                    // to say the press was meant — see `pressBegan(on:)`.
                    onPressBegan: { frame in
                        pressedTile = PressedTile(key: target.id, frame: frame)
                        follow.lean = .zero
                        viewModel.pressBegan(on: target)
                    },
                    // The card leans after the finger while it is held. No
                    // animation on the way out: this is the finger's own
                    // movement, and a spring between the two would lag behind
                    // it. The swing back on release is animated, below.
                    onPressMoved: { translation in
                        guard expansion?.key == target.id else { return }
                        follow.lean = Self.lean(translation)
                    },
                    onPressEnded: {
                        viewModel.pressEnded(on: target)
                        pressedTile = nil
                    },
                    onPressCancelled: {
                        viewModel.pressCancelled(on: target)
                        pressedTile = nil
                    },
                    onRetry: { viewModel.retrySend(on: target) },
                    onDiscard: { viewModel.discardPendingUpload(on: target) }
                )
                // The pop-over copy stands in for the tile from the press
                // until the copy has slid back and is gone. The tile stays in
                // place, invisible, because it owns the gesture that is still
                // in progress; showing it any earlier puts two glass panes
                // and two shadows on top of each other.
                .opacity(expansion?.key == target.id ? 0 : 1)
            }
        }
    }

    /// A binding that passes writes through but always reads `false`.
    ///
    /// The tile that is being held is the one that *sets* the cancel flag, and
    /// it is also the one thing on screen that never has to show it: it sits
    /// invisible under its own pop-over for as long as the press lasts. Handing
    /// the grid the real binding made every tile in it — glass, text and the
    /// spring on `willCancel` — redraw each time the finger crossed the cancel
    /// edge. Only the two pop-over copies get the live value.
    private static func writeOnly(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { false }, set: { binding.wrappedValue = $0 })
    }

    // MARK: - Pop-over

    /// The tile the copy currently stands in for: the one being held, while it
    /// is arming or recording. Releasing (sending) or cancelling gives the
    /// tile back — collapsing the copy first, if it ever grew.
    private var presentedKey: String? {
        guard let expansion else { return nil }
        switch viewModel.cardStates[expansion.key] ?? .idle {
        case .arming, .recording: return expansion.key
        default: return nil
        }
    }

    /// An enlarged copy of the held tile, floating over a dimmed grid. The
    /// copy is display only: the finger is still down on the tile in the grid,
    /// so nothing here may take touches.
    ///
    /// The copy is present from the press until it has slid back onto the
    /// tile. Its geometry is driven by `isPopoverOpen`, not by a transition:
    /// SwiftUI applies a transition around the positioned container, which
    /// would scale about the screen instead of about the card.
    ///
    /// Two renderings travel together and cross-fade: the pop-over layout,
    /// shown while open, and the tile's own layout scaled up, shown while
    /// closed. Type set at pop-over size never matches type set at tile size
    /// when shrunk — SF Pro changes cut and tracking with point size — so the
    /// view that lands on the tile has to be the tile's layout itself.
    private var popover: some View {
        GeometryReader { proxy in
            let local = proxy.frame(in: .global)
            ZStack {
                if let expansion,
                   let target = viewModel.targets.first(where: { $0.id == expansion.key }) {
                    Color.black.opacity(isPopoverOpen ? 0.35 : 0)
                        .ignoresSafeArea()
                        .animation(Self.dimAnimation, value: isPopoverOpen)

                    let scale = Self.collapseScale(expansion)
                    let pane = isPopoverOpen ? expansion.popover : expansion.collapsed
                    ZStack {
                        // The tile as it is in the grid, blown up while open.
                        // The opacity carries its own curve, applied under the
                        // scale so only the fade takes it: the geometry keeps
                        // the ambient spring and is free to overshoot.
                        copy(of: target, expanded: false)
                            .frame(width: expansion.collapsed.width, height: expansion.collapsed.height)
                            .opacity(isPopoverOpen ? 0 : 1)
                            .animation(Self.crossfadeAnimation, value: isPopoverOpen)
                            .scaleEffect(isPopoverOpen ? 1 / scale : 1)

                        // The pop-over layout, shrunk onto the tile while closed.
                        copy(of: target, expanded: true)
                            .frame(width: expansion.popover.width, height: expansion.popover.height)
                            .opacity(isPopoverOpen ? 1 : 0)
                            .animation(Self.crossfadeAnimation, value: isPopoverOpen)
                            .scaleEffect(isPopoverOpen ? 1 : scale)
                    }
                    // Inside the glass: the tilt goes on what is *drawn on*
                    // the pane, and the pane's own material stays flat — see
                    // ``TiltsWithFinger``.
                    .modifier(TiltsWithFinger(pull: follow))
                    // One glass under both renderings. The pane is laid out
                    // at its current size rather than scaled, so its shadow
                    // and edge are the system's at every step and match the
                    // tile's own glass at the moment of handoff. The copies
                    // carry no glass of their own: two translucent layers
                    // cross-fading would double the refraction half-way.
                    .frame(width: pane.width, height: pane.height)
                    // The tile's own material, exactly — see
                    // ``IntercomCard/glass(for:isEnabled:)``. Anything denser here
                    // than in the grid changes materials in the moment the
                    // pane lands on its tile and hands over.
                    .glassEffect(
                        IntercomCard.glass(for: viewModel.state(for: target), isEnabled: viewModel.isPressable(target)),
                        in: RoundedRectangle(
                            cornerRadius: isPopoverOpen ? IntercomCard.expandedCornerRadius : IntercomCard.compactCornerRadius,
                            style: .continuous
                        )
                    )
                    // The whole pane, glass included, follows the finger by
                    // this much. Before `.position`, which would otherwise
                    // hand the modifier a screen-sized layer to move.
                    .modifier(ShiftsWithFinger(pull: follow))
                    // Closed, the pane sits exactly over the tile.
                    .offset(isPopoverOpen ? .zero : Self.collapseOffset(expansion))
                    .position(
                        x: expansion.popover.midX - local.minX,
                        y: expansion.popover.midY - local.minY
                    )
                    .accessibilityHidden(true)
                    // The copy appears closed, exactly over its tile, and
                    // grows from there. The mic waits for the spring to have
                    // actually stopped, not just to have reached the target
                    // — `.logicallyComplete` fired while the card was still
                    // settling, so `AVAudioRecorder`'s main-thread setup
                    // landed on top of the tail of the bounce and read as a
                    // second jerk. `.removed` costs the rest of the settle
                    // in latency; the animation is still the only thing that
                    // knows when either point arrives, so it is what says so.
                    .onAppear {
                        withAnimation(Self.expandAnimation, completionCriteria: .removed) {
                            isPopoverOpen = true
                        } completion: {
                            viewModel.cardDidFinishGrowing(on: target)
                        }
                    }
                    // Backstop for the completion above — see
                    // `expandFallbackDelay`. `cardDidFinishGrowing` is
                    // idempotent, so whichever of the two runs first wins and
                    // the other is a no-op. A `.task`, not a bare `Task {}`,
                    // so it is cancelled the moment this copy is torn down —
                    // by the `.id` below on the next press, or by the
                    // pop-over closing — and can never fire for a press it
                    // does not belong to.
                    .task {
                        try? await Task.sleep(for: Self.expandFallbackDelay)
                        viewModel.cardDidFinishGrowing(on: target)
                    }
                    // A new press while the last copy is still sliding back
                    // gets a fresh copy, which appears closed and opens.
                    .id(expansion.id)
                }
            }
        }
        .onChange(of: viewModel.activeTarget) { _, key in
            // The press has outlasted a tap and claimed its card: build the
            // pop-over over the tile the finger is on. A press that never got
            // here — a tap — never had a pop-over to take down.
            guard let key, let pressed = pressedTile, pressed.key == key else { return }
            isPopoverOpen = false
            // Whatever the finger did on the way here — the slop it is allowed
            // before the press commits — the card opens centred on its tile.
            follow.lean = .zero
            expansion = CardExpansion(
                key: key,
                collapsed: pressed.frame,
                popover: popoverFrame(for: pressed.frame)
            )
        }
        .onChange(of: presentedKey) { _, key in
            // Released, cancelled or interrupted: slide back onto the tile,
            // then take the copy down.
            guard key == nil, let closing = expansion else { return }
            // A press that never grew has nothing to slide back. Handing the
            // tile straight back also keeps this off an animation that has no
            // frames to run and so might never report itself finished.
            guard isPopoverOpen else {
                follow.lean = .zero
                if expansion?.id == closing.id { expansion = nil }
                viewModel.cardDidReturnToGrid()
                return
            }
            withAnimation(Self.collapseAnimation, completionCriteria: .removed) {
                isPopoverOpen = false
                // Swings back to centre as it shrinks, on the same spring, so
                // the copy still lands exactly on its tile.
                follow.lean = .zero
            } completion: {
                if expansion?.id == closing.id { expansion = nil }
                // Landed: now the hint above the grid may go, see
                // ``IntercomViewModel/cardDidReturnToGrid()``.
                viewModel.cardDidReturnToGrid()
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            // The screen minus the safe area, in global coordinates.
            let frame = proxy.frame(in: .global)
            let insets = proxy.safeAreaInsets
            return CGRect(
                x: frame.minX + insets.leading,
                y: frame.minY + insets.top,
                width: frame.width - insets.leading - insets.trailing,
                height: frame.height - insets.top - insets.bottom
            )
        } action: { stage = $0 }
        .allowsHitTesting(false)
    }

    /// How far the card is leaning for a finger that has travelled
    /// `translation`: a fraction per axis, `-1 ... 1`, which
    /// ``ShiftsWithFinger`` and ``TiltsWithFinger`` turn into the pane's shift
    /// and its content's tilt.
    ///
    /// `tanh` rather than a plain fraction: near the tile the card follows the
    /// finger almost proportionally, and the further the finger goes the more
    /// it holds back, easing onto its limit instead of hitting it. Clamping a
    /// fraction would make the card stop dead half-way across the cancel zone;
    /// this way it keeps giving a little the whole way out.
    private static func lean(_ translation: CGSize) -> CGSize {
        CGSize(
            width: tanh(translation.width / leanReach),
            height: tanh(translation.height / leanReach)
        )
    }

    /// Twice the tile, centred on it.
    private static func doubled(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -rect.width / 2, dy: -rect.height / 2)
    }

    /// Twice the tile, centred on it and only nudged onto the screen where it
    /// would otherwise stick out.
    ///
    /// The card grows around its own tile rather than appearing at one fixed
    /// spot: the finger stays on the tile in the grid, so a card somewhere
    /// else would leave the finger at — or past — its edge for the tiles in
    /// the top and bottom rows, and cancel the recording the moment it began.
    /// Centred on the tile, the finger starts in the middle of the cancel
    /// zone wherever on the grid the tile sits.
    private func popoverFrame(for collapsed: CGRect) -> CGRect {
        let bounds = stage.insetBy(dx: Self.popoverInset, dy: Self.popoverInset)
        // Before the screen has been measured there is nothing to fit into.
        guard !bounds.isEmpty else { return Self.doubled(collapsed) }
        let size = CGSize(
            width: min(collapsed.width * 2, bounds.width),
            height: min(collapsed.height * 2, bounds.height)
        )
        let doubled = Self.doubled(collapsed)
        return CGRect(
            origin: CGPoint(
                x: Self.fit(doubled.minX, size.width, into: bounds.minX...bounds.maxX, covering: collapsed.minX...collapsed.maxX),
                y: Self.fit(doubled.minY, size.height, into: bounds.minY...bounds.maxY, covering: collapsed.minY...collapsed.maxY)
            ),
            size: size
        )
    }

    /// Slides a span of `length` starting at `origin` onto the screen, but
    /// never so far that it stops covering the tile — the finger is on the
    /// tile, and it has to stay inside the card that holds the cancel zone.
    private static func fit(
        _ origin: CGFloat,
        _ length: CGFloat,
        into bounds: ClosedRange<CGFloat>,
        covering tile: ClosedRange<CGFloat>
    ) -> CGFloat {
        let onScreen = min(max(origin, bounds.lowerBound), bounds.upperBound - length)
        return min(max(onScreen, tile.upperBound - length), tile.lowerBound)
    }

    /// A display-only rendering of a tile for the pop-over. The pop-over
    /// supplies the glass, so the copies draw none.
    private func copy(of target: IntercomTarget, expanded: Bool) -> IntercomCard {
        IntercomCard(
            target: target,
            state: viewModel.state(for: target),
            isEnabled: viewModel.isPressable(target),
            isAvailable: viewModel.isAvailable,
            isExpanded: expanded,
            recorder: viewModel.levelMeter,
            showsGlass: false,
            willCancel: $willCancel,
            onPressBegan: { _ in },
            onPressEnded: {}
        )
    }

    /// The scale that shrinks the pop-over to its tile's size.
    private static func collapseScale(_ expansion: CardExpansion) -> CGFloat {
        guard expansion.popover.height > 0, expansion.collapsed.height > 0 else { return 0.5 }
        return expansion.collapsed.height / expansion.popover.height
    }

    /// Moves the (shrunk) pop-over's centre onto the tile's centre.
    private static func collapseOffset(_ expansion: CardExpansion) -> CGSize {
        CGSize(
            width: expansion.collapsed.midX - expansion.popover.midX,
            height: expansion.collapsed.midY - expansion.popover.midY
        )
    }

    private var serverTooOld: some View {
        ContentUnavailableView {
            Label("intercom_server_too_old_title", systemImage: "megaphone")
        } description: {
            Text("intercom_server_too_old_message")
        }
    }

    private var noPlayers: some View {
        ContentUnavailableView {
            Label("intercom_no_players_title", systemImage: "hifispeaker")
        } description: {
            Text("intercom_no_players_message")
        }
    }

    /// The one place the gesture is spelled out. It used to sit on every tile
    /// as "Halten" — the same word under a dozen microphones, saying nothing
    /// about the player it was on. One quiet line above the grid says it once,
    /// and scrolls away with the rest of the content.
    ///
    /// It only appears once someone has tapped a card instead of holding it
    /// (see ``IntercomViewModel/showsHoldHint``): that tap is the question the
    /// line answers, and until it is asked the grid says nothing.
    private var hint: some View {
        Text("intercom_hold_hint")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // The tiles carry the gesture in their own accessibility hints,
            // where VoiceOver reads it on the card it applies to; announcing
            // it again as a line of its own only puts it in the way.
            .accessibilityHidden(true)
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

/// How far the open pop-over is leaning after the finger: a fraction per axis,
/// `-1 ... 1`, where 1 is the full lean to the right or downwards.
///
/// A box rather than `@State` for the same reason `RoomCard` keeps its press in
/// one: this is written on every touch-move, and in `@State` each of those
/// writes would re-render the whole pop-over — two card copies, their glass and
/// the live waveform — sixty times a second while the finger moves. Only
/// ``ShiftsWithFinger`` and ``TiltsWithFinger`` read it, so only those two
/// modifiers redraw.
@Observable
private final class FingerPull {
    /// Touched only from the main thread, where the gesture callbacks arrive.
    var lean: CGSize = .zero
}

/// Moves the whole pop-over, glass and all, a little way after the finger.
///
/// Barely any travel: the card is held, not dragged, and one that went with the
/// finger left its tile behind and read as drag-and-drop. This is only what
/// keeps the tilt from looking hinged in place.
private struct ShiftsWithFinger: ViewModifier {
    let pull: FingerPull

    /// How far the card shifts at a full lean.
    private static let shift: CGFloat = 6

    func body(content: Content) -> some View {
        content.offset(x: pull.lean.width * Self.shift, y: pull.lean.height * Self.shift)
    }
}

/// Tilts what is drawn on the pop-over about the axis across the finger's
/// travel: the edge the finger is heading for leans away, the opposite one
/// comes forward.
///
/// Applied *inside* the glass, to the card's content alone, because Liquid
/// Glass does not take a 3D transform with it: turning the pane as a whole
/// left its material sitting flat behind a tilted card, showing its edge as a
/// second rounded rectangle beside it — with `compositingGroup()` in front of
/// the rotation just as much as without. So the pane stays flat and square to
/// the screen, and the type and the waveform lean inside it.
private struct TiltsWithFinger: ViewModifier {
    let pull: FingerPull

    /// How far the content tips at a full lean. Past a few degrees the type on
    /// the receding side starts to blur.
    private static let tilt: CGFloat = 7
    /// Foreshortening, well under the default 1: the card is held at arm's
    /// length and a strong vanishing point makes a 7° tilt look like a 20°
    /// one, complete with a near edge that grows.
    private static let perspective: CGFloat = 0.5

    func body(content: Content) -> some View {
        let lean = pull.lean
        let amount = min(hypot(lean.width, lean.height), 1)
        // A zero vector has no direction to normalise; at rest the angle is
        // zero anyway, so any axis will do.
        let axis: (x: CGFloat, y: CGFloat, z: CGFloat) = amount > 0
            ? (x: -lean.height, y: lean.width, z: 0)
            : (x: 0, y: 1, z: 0)
        return content.rotation3DEffect(
            .degrees(amount * Self.tilt),
            // Perpendicular to the travel, in SwiftUI's y-down space: a
            // finger moving right turns the content about its vertical axis
            // and sends the right edge back; moving down tips the bottom
            // back. `rotation3DEffect` normalises the axis itself, so the
            // lean only has to point it.
            axis: axis,
            perspective: Self.perspective
        )
    }
}

extension IntercomViewModel {
    /// The one the tab uses: the Kotlin sender, and an audio session that
    /// stays out of the local player's way.
    static func live() -> IntercomViewModel {
        IntercomViewModel(
            sender: KmpAnnouncementSender(),
            recorder: IntercomRecorder(
                engine: IntercomAudioSession(isLocalPlaybackActive: {
                    (PlatformPlayerProvider.shared.player as? NativeAudioController)?.isRenderingAudio == true
                })
            )
        )
    }
}

/// Whether the signed-in server takes spoken announcements, from
/// `KmpHelper.announcementAvailability`, and whether it is known to be too old
/// for them.
@MainActor
@Observable
final class IntercomAvailability {
    private(set) var voice = false
    private(set) var serverTooOld = false

    @ObservationIgnored private var subscription: Cancellable?

    func start() {
        guard subscription == nil else { return }
        subscription = KmpHelper.shared.announcementAvailability.subscribe { [weak self] availability in
            guard let self else { return }
            let voice = availability?.voice ?? false
            if voice != self.voice { self.voice = voice }
            let tooOld = KmpHelper.shared.isServerTooOldForSpokenAnnouncements()
            if tooOld != serverTooOld { serverTooOld = tooOld }
        }
    }
}
