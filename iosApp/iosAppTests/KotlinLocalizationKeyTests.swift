import XCTest

/// Guards the one string path that fails silently.
///
/// Phase F moved the shared core off compose-resources, whose `Res.string.foo` was a generated
/// symbol — a typo or a removed key was a compile error. The replacement, Kotlin's
/// `localizedString("foo")`, takes a plain `String` and resolves through `NSBundle`, which
/// returns the key itself when it can't find one. So a bad key doesn't fail the build, fail a
/// test, or throw at runtime: it just puts `media_playback_stopped_connection_lost` on screen
/// where a sentence should be, in whichever locale nobody checked.
///
/// This scans the Kotlin sources for every `localizedString("…")` call and asserts each key
/// exists in the catalog, so the two can't drift apart unnoticed. It reads the repo through
/// `#filePath` rather than the test bundle: `iosAppTests` has no host app, so `Bundle.main` is
/// the xctest bundle and has no `.lproj` to look in.
final class KotlinLocalizationKeyTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // iosAppTests
        .deletingLastPathComponent()  // iosApp
        .deletingLastPathComponent()  // repo root

    func testEveryKotlinLocalizationKeyExistsInTheCatalog() throws {
        let keys = try kotlinLocalizationKeys()

        // A scan that silently finds nothing would pass forever while proving nothing — most
        // likely because the call was renamed or the sources moved out from under `#filePath`.
        XCTAssertFalse(
            keys.isEmpty,
            "Found no localizedString(\"…\") calls in composeApp/src. Either the helper was "
                + "renamed or this test is looking in the wrong place; it is not evidence of health."
        )

        let catalog = try catalogKeys()
        let missing = keys.filter { !catalog.contains($0.key) }.sorted { $0.key < $1.key }

        XCTAssertTrue(
            missing.isEmpty,
            "Kotlin looks up keys that Localizable.xcstrings doesn't define. These would render "
                + "as the raw key at runtime:\n"
                + missing.map { "  \($0.key)  — \($0.file)" }.joined(separator: "\n")
        )
    }

    // MARK: - Sources

    private struct KeyUse {
        let key: String
        let file: String
    }

    /// Every `localizedString("…")` argument in the Kotlin sources, with the file it came from.
    /// Deliberately literal-only: the helper is meant to be called with a constant, and a
    /// computed key is exactly the thing this test could not check anyway.
    private func kotlinLocalizationKeys() throws -> [KeyUse] {
        let sources = Self.repoRoot.appendingPathComponent("composeApp/src")
        let pattern = try NSRegularExpression(pattern: #"localizedString\(\s*"([^"]+)"\s*\)"#)

        guard
            let walker = FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil
            )
        else {
            XCTFail("Cannot enumerate \(sources.path)")
            return []
        }

        var found: [KeyUse] = []
        for case let url as URL in walker where url.pathExtension == "kt" {
            // The declaration itself lives in Localization.kt / Localization.ios.kt and has no
            // literal argument to match, so it drops out on its own.
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            let name = url.lastPathComponent
            for match in pattern.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
                found.append(KeyUse(key: String(text[keyRange]), file: name))
            }
        }
        return found
    }

    /// Keys defined in the string catalog. Parsed as JSON — `.xcstrings` is a JSON document, and
    /// the top-level `strings` object is keyed by the lookup key.
    private func catalogKeys() throws -> Set<String> {
        let catalog = Self.repoRoot.appendingPathComponent("iosApp/iosApp/Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let strings = root?["strings"] as? [String: Any] else {
            XCTFail("Unexpected .xcstrings shape at \(catalog.path)")
            return []
        }
        return Set(strings.keys)
    }
}
