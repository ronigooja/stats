#!/usr/bin/env python3
"""Run with python3 Tests/remote-i18n.py; static localization checks only."""

from collections import Counter
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
LANGS = ("en", "zh-Hans", "zh-Hant")
SWIFT = [ROOT / "Modules/Remote" / name for name in ("settings.swift", "mqtt.swift", "main.swift", "popup.swift")]
SWIFT.append(ROOT / "Kit/plugins/MQTTReport.swift")
# These are the keys added for this task; en contains identity translations.
ADDED = [
    "Apply", "Broker", "Connecting…", "Could not save the password locally", "Device ID", "Disconnected",
    "Enter a host, a port (1–65535) and valid credentials", "Host", "Load average", "Password", "Port",
    "Report interval", "Report this Mac", "Reporting off", "Saved", "Show machines", "This Mac", "Username",
    "+%d more", "Invalid CONNACK", "Protocol version rejected", "Client identifier rejected", "Server unavailable",
    "Username or password rejected", "Not authorized", "Connection refused", "Connected · waiting for machines",
    "Connected · %d machines", "Connected, but no machines received. Check that this account can read stats/v1/machines/#",
    "%@; retrying…", "Send failed", "Reporting as %@", "Invalid host, port or device ID",
]
TRADITIONAL = set("裝連網記憶體磁碟開機回報儲顯關帳間套")
SIMPLIFIED = set("设连网络内盘启报发储显关户间应")


def strings(path):
    result = {}
    syntax = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*(?://.*)?$')
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith('"'):
            match = syntax.match(line)
            if match:
                result[match.group(1)] = match.group(2)
    return result


class RemoteLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.tables = {lang: strings(ROOT / "Stats/Supporting Files" / f"{lang}.lproj/Localizable.strings") for lang in LANGS}
        self.source = "\n".join(path.read_text() for path in SWIFT)

    def test_all_localized_literal_keys_exist(self):
        keys = set(re.findall(r'localizedString\("((?:[^"\\]|\\.)*)"', self.source))
        for lang, table in self.tables.items():
            self.assertFalse(keys - table.keys(), f"{lang} missing: {sorted(keys - table.keys())}")

    def test_added_lines_are_valid_and_not_duplicated(self):
        for lang in LANGS:
            path = ROOT / "Stats/Supporting Files" / f"{lang}.lproj/Localizable.strings"
            lines = path.read_text().splitlines()
            for key in ADDED:
                occurrences = [line for line in lines if re.match(rf'^"{re.escape(key)}"\s*=', line)]
                if key in self.tables[lang]:
                    self.assertEqual(len(occurrences), 1, f"{lang}: duplicate/missing {key}")
                    self.assertRegex(occurrences[0], r'^"(?:[^"\\]|\\.)*"\s*=\s*"(?:[^"\\]|\\.)*";')

    def test_added_placeholders_match(self):
        for key in ADDED:
            if key not in self.tables["en"]:
                continue
            expected = Counter(re.findall(r'%(?:d|%@)', self.tables["en"][key]))
            for lang in LANGS[1:]:
                self.assertEqual(expected, Counter(re.findall(r'%(?:d|%@)', self.tables[lang][key])), f"{lang}: {key}")

    def test_added_chinese_script_samples(self):
        hans, hant = self.tables["zh-Hans"], self.tables["zh-Hant"]
        for key in ADDED:
            self.assertFalse(set(hans[key]) & TRADITIONAL, f"Traditional sample in zh-Hans {key}")
            self.assertFalse(set(hant[key]) & SIMPLIFIED, f"Simplified sample in zh-Hant {key}")


if __name__ == "__main__":
    unittest.main()
