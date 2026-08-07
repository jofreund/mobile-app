#!/usr/bin/env python3
"""
Converts the Android/Compose strings.xml resource files into a single Apple
String Catalog (.xcstrings), reusing the existing translated text so the two
stay in sync until Phase D's Lokalise-driven export replaces this script.

Deliberately a one-shot conversion tool, not a build step: this repo has no
Lokalise credentials available in this environment, so this approximates
what that export would produce. Re-run by hand after future string changes
until the real Lokalise iOS export is wired up.
"""
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RES_DIR = REPO / "composeApp/src/commonMain/composeResources"
OUT_PATH = REPO / "iosApp/iosApp/Localizable.xcstrings"

# Android values-<qualifier> -> Apple locale id.
LOCALE_MAP = {
    "values": "en",
    "values-de": "de",
    "values-nl": "nl",
    "values-sr": "sr",
    "values-zh-rCN": "zh-Hans",
}

# Keys already hand-curated in the existing catalog with explanatory comments
# worth preserving verbatim rather than overwriting with a generic one.
EXISTING_COMMENTS = {}
if OUT_PATH.exists():
    existing = json.loads(OUT_PATH.read_text())
    for key, entry in existing.get("strings", {}).items():
        if "comment" in entry:
            EXISTING_COMMENTS[key] = entry["comment"]


def android_placeholders_to_apple(value: str) -> str:
    """%1$s -> %1$@ (Swift String args need %@, not %s); %1$d stays %1$d."""
    return re.sub(r"%(\d+\$)s", r"%\1@", value)


def unescape_android(value: str) -> str:
    # XML entities are already resolved by ElementTree. What's left is
    # Android-specific backslash-escaping inside the text content.
    value = value.replace("\\'", "'").replace('\\"', '"')
    value = value.replace("\\n", "\n")
    # Android wraps literal leading/trailing whitespace in "..."; strip a
    # matching pair of quotes if the whole value is quoted that way.
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
    return value


def parse_strings_xml(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    tree = ET.parse(path)
    result = {}
    for el in tree.getroot().findall("string"):
        name = el.get("name")
        if name is None:
            continue
        # itertext() to pick up mixed content (e.g. stray <xliff:g> the app
        # doesn't use here, but defensive regardless); ElementTree already
        # decodes standard XML entities.
        text = "".join(el.itertext())
        result[name] = unescape_android(android_placeholders_to_apple(text))
    return result


def main() -> None:
    per_locale: dict[str, dict[str, str]] = {}
    for qualifier, apple_locale in LOCALE_MAP.items():
        per_locale[apple_locale] = parse_strings_xml(RES_DIR / qualifier / "strings.xml")

    all_keys = sorted(per_locale["en"].keys())
    missing_in_base = set()
    for apple_locale, table in per_locale.items():
        if apple_locale == "en":
            continue
        extra = set(table.keys()) - set(all_keys)
        if extra:
            missing_in_base |= extra

    strings_out = {}
    for key in all_keys:
        localizations = {}
        for apple_locale, table in per_locale.items():
            if key in table:
                localizations[apple_locale] = {
                    "stringUnit": {"state": "translated", "value": table[key]}
                }
        entry = {"localizations": localizations}
        if key in EXISTING_COMMENTS:
            entry["comment"] = EXISTING_COMMENTS[key]
        strings_out[key] = entry

    catalog = {
        "sourceLanguage": "en",
        "strings": dict(sorted(strings_out.items())),
        "version": "1.0",
    }

    OUT_PATH.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")

    print(f"Wrote {len(strings_out)} keys across {len(per_locale)} locales to {OUT_PATH}")
    for apple_locale, table in per_locale.items():
        print(f"  {apple_locale}: {len(table)} translated")
    if missing_in_base:
        print(f"WARNING: keys present in a locale but not in base 'en': {sorted(missing_in_base)}")


if __name__ == "__main__":
    main()
