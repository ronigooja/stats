#!/usr/bin/env python3
"""Run with python3 Tests/remote-details.py; static checks only, no Swift build."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RemoteDetailsTests(unittest.TestCase):
    def setUp(self):
        self.main = (ROOT / 'Modules/Remote/main.swift').read_text()
        self.mqtt = (ROOT / 'Modules/Remote/mqtt.swift').read_text()
        self.details = self.main.split('public var details: String {', 1)[1].split('public struct RemoteModules', 1)[0]

    def test_disks_decoding_is_lossy_and_bounded(self):
        for text in ['struct DiskEntry: Decodable', 'struct Disks: Decodable',
                     'let disks: Disks?', 'try? decoder.unkeyedContainer()',
                     'try? decoder.container(keyedBy: CodingKeys.self)',
                     'try? container.decode(String.self, forKey: .mount)',
                     'try? container.decode(Double.self, forKey: .used_bytes)',
                     'try? container.decode(Double.self, forKey: .total_bytes)',
                     'used.isFinite, total.isFinite, total > 0',
                     'mount.trimmingCharacters(in: .whitespacesAndNewlines)',
                     'trimmedMount.isEmpty ? nil', 'min(max(used, 0), total)',
                     'while !container.isAtEnd, entries.count < 32',
                     'if let value = entry.value { entries.append(value) }']:
            self.assertIn(text, self.mqtt)
        self.assertIn('public struct RemoteDiskEntry: Codable', self.main)
        self.assertIn('public let disks: [RemoteDiskEntry]?', self.main)

    def test_tooltip_caps_mounts_and_keeps_aggregate_fallback(self):
        for text in ['if let disks = self.modules?.disks, disks.count >= 2',
                     'for disk in disks.prefix(8)', '\\(disk.mount):',
                     'if disks.count > 8', 'disks.count - 8',
                     'String(format: localizedString("+%d more")',
                     '} else if let disk = self.modules?.disk {',
                     'Units(bytes: Int64(disk.used)).getReadableMemory()',
                     'Units(bytes: Int64(disk.total)).getReadableMemory()']:
            self.assertIn(text, self.details)
        self.assertNotIn('Last update', self.details)
        self.assertNotIn('lastSeenTS', self.details)
        self.assertNotIn('.sorted', self.details)
        english = (ROOT / 'Stats/Supporting Files/en.lproj/Localizable.strings').read_text()
        self.assertIn('"+%d more" = "+%d more";', english)

    def test_every_modules_construction_threads_disks(self):
        calls = []
        for path in ROOT.rglob('*.swift'):
            source = path.read_text()
            for match in re.finditer(r'\bRemoteModules\s*\(', source):
                start = match.end()
                depth = 1
                end = start
                while depth and end < len(source):
                    depth += (source[end] == '(') - (source[end] == ')')
                    end += 1
                self.assertEqual(depth, 0, str(path))
                call = source[start:end - 1]
                self.assertRegex(call, r'\bdisks\s*:', str(path))
                calls.append(call)
        self.assertTrue(calls)
        self.assertIn('disks: value.metrics?.disks?.entries', self.mqtt)


if __name__ == '__main__':
    unittest.main()
