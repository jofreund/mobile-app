import Foundation

/// Every way a spoken announcement can fail, already phrased for the card —
/// home-intercom's `APIError`, cut down to what the live-announcement socket
/// can report.
///
/// The server plays every clip that has audio in it, also when the link drops
/// half-way. So the one thing a failure must say is how far the clip got,
/// because that decides whether "Erneut senden" could play it twice.
enum AnnouncementError: Error, Equatable, LocalizedError, Sendable {
    /// Nothing reached the server: no connection, no channel, or the server
    /// turned the clip down before any audio went out (with its reason, when
    /// it gave one). Safe to resend.
    case notSent(reason: String?)
    /// The link went away while the clip was going out. The server plays the
    /// part that arrived.
    case cutShort
    /// The whole clip went out and the server reported that playing it failed.
    case playbackFailed(reason: String?)

    var message: String {
        switch self {
        case .notSent(let reason):
            reason ?? String(localized: "intercom_error_not_sent")
        case .cutShort:
            String(localized: "intercom_error_cut_short")
        case .playbackFailed(let reason):
            reason ?? String(localized: "intercom_error_playback_failed")
        }
    }

    var errorDescription: String? { message }

    /// Whether the announcement may already have played, in part or in full,
    /// even though the app saw a failure. Resending in that case plays it again.
    var mayHaveBeenDelivered: Bool {
        switch self {
        case .notSent: false
        case .cutShort, .playbackFailed: true
        }
    }

    /// What the kernel's `ClipResult` means for the card: `nil` for a clip
    /// that played — or that will, because all of it and the stop went out
    /// before the link was lost, and the server plays what it has.
    static func from(played: Bool, reason: String?, audioSent: Bool, stopSent: Bool) -> AnnouncementError? {
        if played { return nil }
        if stopSent { return reason.map { .playbackFailed(reason: $0) } }
        if audioSent { return .cutShort }
        return .notSent(reason: reason)
    }
}
