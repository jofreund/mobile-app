import Foundation

/// Pure UI-side validation, ported verbatim from `Ext.kt`'s `isValidHost`/`isIpPort` and
/// `RemoteId.parse`/`isValid` — these only drive Connect-button enablement and inline error
/// text. Kotlin's own `RemoteId.parse`/`ConnectionInfo` construction (in
/// `KmpHelper.attemptConnection`/`attemptWebRTCConnection`) remain the real gate before
/// anything reaches the server, so a divergence here would be a UX bug, not a protocol one.
enum ConnectionValidation {

    private static let ipLikePattern = try! NSRegularExpression(pattern: #"^(-?\d{1,3}\.)+-?\d{1,3}$"#)
    private static let ipv4Pattern = try! NSRegularExpression(
        pattern: #"^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"#
    )
    private static let hostnamePattern = try! NSRegularExpression(
        pattern: #"^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.[A-Za-z0-9-]{1,63})*(?<!\.)$"#
    )
    private static let remoteIdPattern = try! NSRegularExpression(pattern: "^[A-Z0-9]{26}$")

    private static func fullMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return false }
        return match.range == range
    }

    static func isValidHost(_ text: String) -> Bool {
        if fullMatch(ipLikePattern, text) {
            return fullMatch(ipv4Pattern, text)
        }
        return fullMatch(hostnamePattern, text)
    }

    static func isIpPort(_ text: String) -> Bool {
        guard let port = Int(text) else { return false }
        return (1...65535).contains(port)
    }

    /// Mirrors `RemoteId.parse`: strips hyphens/whitespace, uppercases, then validates.
    /// Returns the normalized 26-character id, or `nil` if the input can never be valid.
    static func normalizedRemoteId(_ input: String) -> String? {
        let cleaned = input
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        return fullMatch(remoteIdPattern, cleaned) ? cleaned : nil
    }

    static func isValidRemoteId(_ input: String) -> Bool {
        normalizedRemoteId(input) != nil
    }
}

extension String {
    var isValidHost: Bool { ConnectionValidation.isValidHost(self) }
    var isIpPort: Bool { ConnectionValidation.isIpPort(self) }
    var isValidRemoteId: Bool { ConnectionValidation.isValidRemoteId(self) }
}
