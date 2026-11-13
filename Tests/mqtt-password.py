#!/usr/bin/env python3
"""Run with python3 Tests/mqtt-password.py; static checks only, no secrets read."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MQTTPasswordTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / 'Kit/plugins/MQTTReport.swift').read_text()

    def test_local_encryption_without_keychain(self):
        for text in ['import CryptoKit', 'AES.GCM.seal', 'AES.GCM.open',
                     'AES.GCM.SealedBox(combined:', 'combined.base64EncodedString()',
                     'Remote_mqtt_password_enc', 'SymmetricKey(size: .bits256)',
                     'data.count == 32', '.applicationSupportDirectory',
                     'appendingPathComponent("Stats", isDirectory: true)',
                     'appendingPathComponent("mqtt.key")', '0o600', '0o700',
                     'O_EXCL | O_NOFOLLOW', 'Store.shared.remove(self.passwordKey)']:
            self.assertIn(text, self.source)
        self.assertNotIn('SecItem', self.source)
        self.assertNotIn('import Security', self.source)

    def test_reads_and_failures_are_cached_under_lock(self):
        getter = self.source.split('public static var password: String', 1)[1].split('public static func savePassword', 1)[0]
        self.assertIn('self.passwordLock.lock()', getter)
        self.assertIn('defer { self.passwordLock.unlock() }', getter)
        self.assertLess(getter.index('if let value = self.cachedPassword'), getter.index('Store.shared.string'))
        self.assertLess(getter.index('self.cachedPassword = ""'), getter.index('AES.GCM.open'))
        saver = self.source.split('public static func savePassword', 1)[1].split('public enum MQTTWire', 1)[0]
        self.assertIn('self.passwordLock.lock()', saver)
        self.assertIn('defer { self.passwordLock.unlock() }', saver)
        self.assertIn('self.cachedPassword = nil', saver)
        self.assertIn('self.cachedPassword = value', saver)


if __name__ == '__main__':
    unittest.main()
