#!/usr/bin/env python3
"""Run with python3 Tests/keepalive.py; static checks only, no Swift build."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class KeepAliveTests(unittest.TestCase):
    def setUp(self):
        self.reporter = (ROOT / 'Kit/plugins/MQTTReport.swift').read_text()
        self.subscriber = (ROOT / 'Modules/Remote/mqtt.swift').read_text()

    def test_connect_encodes_uint16_keepalive_big_endian(self):
        connect = self.reporter.split('public static func connect(', 1)[1].split('public static func publish(', 1)[0]
        self.assertIn('keepAlive: UInt16 = 60', connect)
        self.assertIn('body += [flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 255)]', connect)
        self.assertNotIn('[flags, 0, 60]', connect)

    def test_reporter_uses_bounded_keepalive(self):
        helper = self.reporter.split('public static var keepAlive: UInt16', 1)[1].split('public static var deviceID:', 1)[0]
        self.assertIn('let seconds = max(60, min(interval, 300) * 2)', helper)
        self.assertIn('return UInt16(seconds)', helper)
        for interval, expected in [(5, 60), (10, 60), (30, 60), (60, 120),
                                   (300, 600), (600, 600), (3600, 600),
                                   ((1 << 63) - 1, 600)]:
            with self.subTest(interval=interval):
                self.assertEqual(max(60, min(interval, 300) * 2), expected)
        opening = self.reporter.split('private func open()', 1)[1].split('private func receive(', 1)[0]
        self.assertIn('will: will, keepAlive: MQTTConfig.keepAlive', opening)

    def test_settings_changes_reconnect_reporter(self):
        settings = self.reporter.split('@objc private func settingsChanged()', 1)[1].split('private func ensureRunning()', 1)[0]
        self.assertIn('self.teardown(sendOffline: true)', settings)
        self.assertIn('if MQTTConfig.reporting { self.ensureRunning() }', settings)
        self.assertLess(settings.index('self.teardown('), settings.index('self.ensureRunning()'))

    def test_subscriber_keeps_default_keepalive_and_watchdog(self):
        connect = self.subscriber.split('MQTTWire.connect(', 1)[1].split('self.receive(', 1)[0]
        self.assertNotIn('keepAlive:', connect)
        self.assertIn('Timer(timeInterval: 45, repeats: true)', self.subscriber)
        self.assertIn('self.timer?.tolerance = 10', self.subscriber)
        self.assertLess(self.subscriber.index('self.timer?.tolerance = 10'), self.subscriber.index('RunLoop.main.add('))
        self.assertIn('Date().timeIntervalSince(self.lastResponse) > (self.connected ? 90 : 30)', self.subscriber)
        self.assertIn('self.send(MQTTWire.packet(0xC0, []))', self.subscriber)
        parsing = self.subscriber.split('private func parse()', 1)[1].split('private func connack(', 1)[0]
        self.assertIn('self.lastResponse = Date()', parsing)


if __name__ == '__main__':
    unittest.main()
