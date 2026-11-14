#!/usr/bin/env python3
"""Run with python3 Tests/power.py; static checks only, no Swift build."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PowerTests(unittest.TestCase):
    def setUp(self):
        self.reporter = (ROOT / 'Kit/plugins/MQTTReport.swift').read_text()
        self.subscriber = (ROOT / 'Modules/Remote/mqtt.swift').read_text()
        self.reader = (ROOT / 'Modules/Remote/reader.swift').read_text()

    def test_reporter_guards_queue_hop_with_locked_flag(self):
        update = self.reporter.split('public func update(value: Any)', 1)[1].split('public func set(', 1)[0]
        self.assertIn('guard MQTTConfig.reporting,', update)
        self.assertLess(update.index('guard MQTTConfig.reporting,'), update.index('metrics.apply(to: self)'))
        self.assertLess(update.index('metrics.apply(to: self)'), update.index('guard !self.running else { return }'))
        self.assertLess(update.index('guard !self.running else { return }'), update.index('self.queue.async'))
        flag = self.reporter.split('private var running: Bool', 1)[1].split('private var cpu:', 1)[0]
        self.assertIn('private let runningLock = NSLock()', self.reporter)
        self.assertIn('private var _running = false', self.reporter)
        self.assertEqual(flag.count('self.runningLock.lock()'), 2)
        self.assertEqual(flag.count('defer { self.runningLock.unlock() }'), 2)
        self.assertIn('return self._running', flag)
        self.assertIn('self._running = newValue', flag)
        opening = self.reporter.split('private func open()', 1)[1].split('private func receive(', 1)[0]
        self.assertLess(opening.index('self.running = true'), opening.index('connection.start(queue: self.queue)'))
        failure = self.reporter.split('private func failed(', 1)[1].split('private func teardown(', 1)[0]
        self.assertIn('self.reconnect = nil\n            self.running = false\n            self.ensureRunning()', failure)
        self.assertIn('self.reconnect = item\n        self.running = true', failure)
        teardown = self.reporter.split('private func teardown(', 1)[1]
        self.assertIn('self.running = false', teardown)

    def test_repeating_timers_allow_coalescing(self):
        self.assertIn('Timer(timeInterval: 20, repeats: true)', self.subscriber)
        self.assertIn('self.timer?.tolerance = 5', self.subscriber)
        self.assertLess(self.subscriber.index('self.timer?.tolerance = 5'), self.subscriber.index('RunLoop.main.add('))
        self.assertIn('repeating: .seconds(MQTTConfig.interval)', self.reporter)
        self.assertIn('leeway: .seconds(max(1, MQTTConfig.interval / 10))', self.reporter)
        self.assertIn('self.interval = 60', self.reader)
        self.assertIn('DispatchQueue.main.async', self.reader)
        self.assertNotIn('Timer(', self.reader)

    def test_subscriber_coalesces_and_cancels_delivery(self):
        self.assertIn('private let snapshotDelay: TimeInterval = 0.5', self.subscriber)
        self.assertIn('private var pendingSnapshot: DispatchWorkItem?', self.subscriber)
        message = self.subscriber.split('private func message(', 1)[1].split('private func scheduleSnapshot()', 1)[0]
        self.assertIn('self.machines[id] = machine', message)
        self.assertIn('self.scheduleSnapshot()', message)
        self.assertNotIn('self.publish()', message)
        delivery = self.subscriber.split('private func scheduleSnapshot()', 1)[1].split('private func publish()', 1)[0]
        self.assertIn('guard !self.stopped, self.pendingSnapshot == nil else { return }', delivery)
        self.assertIn('DispatchWorkItem { [weak self] in', delivery)
        self.assertIn('guard let self, !self.stopped else { return }', delivery)
        self.assertIn('self.pendingSnapshot = nil\n            self.publish()', delivery)
        self.assertIn('DispatchQueue.main.asyncAfter(deadline: .now() + self.snapshotDelay, execute: item)', delivery)
        stop = self.subscriber.split('func stop()', 1)[1].split('private func open()', 1)[0]
        self.assertIn('self.pendingSnapshot?.cancel()', stop)
        self.assertIn('self.pendingSnapshot = nil', stop)
        start = self.subscriber.split('func start()', 1)[1].split('func stop()', 1)[0]
        self.assertEqual(start.count('self.publish()'), 2)


if __name__ == '__main__':
    unittest.main()
