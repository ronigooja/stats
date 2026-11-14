#!/usr/bin/env python3
"""Run with python3 Tests/gpu.py; static checks only, no Swift build."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GPUTests(unittest.TestCase):
    def setUp(self):
        self.reporter = (ROOT / 'Kit/plugins/MQTTReport.swift').read_text()
        self.gpu = (ROOT / 'Modules/GPU/main.swift').read_text()
        self.main = (ROOT / 'Modules/Remote/main.swift').read_text()
        self.mqtt = (ROOT / 'Modules/Remote/mqtt.swift').read_text()

    def test_reporter_gpu_is_optional_and_queue_confined(self):
        self.assertIn('private var gpu: Double?', self.reporter)
        setter = self.reporter.split('public func set(', 1)[1].split('public func clearGPU()', 1)[0]
        self.assertIn('load1: Double? = nil, gpu: Double? = nil)', setter)
        self.assertIn('if let gpu { self.gpu = gpu }', setter)
        self.assertLess(setter.index('self.queue.async'), setter.index('self.gpu = gpu'))
        clear = self.reporter.split('public func clearGPU()', 1)[1].split('public func stop()', 1)[0]
        self.assertIn('self.queue.async { [weak self] in self?.gpu = nil }', clear)

    def test_gpu_does_not_satisfy_reporter_readiness(self):
        publish = self.reporter.split('private func publishMetrics()', 1)[1].split('private func send(', 1)[0]
        gpu = 'if let gpu { metrics["gpu_percent"] = (gpu * 10000).rounded() / 100 }'
        self.assertIn(gpu, publish)
        self.assertLess(publish.index('guard metrics.count > 3 else { return }'), publish.index(gpu))
        self.assertLess(publish.index(gpu), publish.index('JSONSerialization.data(withJSONObject: metrics)'))

    def test_gpu_uses_exact_summary_selection_and_clears_all_nil_paths(self):
        self.assertIn('import Kit', self.gpu)
        self.assertIn('public var utilization: Double? = nil', self.gpu)
        callback = self.gpu.split('private func infoCallback(', 1)[1]
        self.assertIn('let selectedGPU: GPU_Info = activeGPUs.first{ $0.model == self.selectedGPU } ?? activeGPU', callback)
        self.assertIn('guard let utilization = selectedGPU.utilization else {', callback)
        self.assertIn('self.summaryCallback(utilization)\n        if MQTTConfig.reporting { MQTTReporter.shared.set(gpu: utilization) }', callback)
        self.assertIn('ColorValue(utilization)', callback)
        nil_paths = re.findall(r'self\.summaryCallback\(nil\)(.*?)return', callback, re.S)
        self.assertEqual(len(nil_paths), 3)
        for path in nil_paths:
            self.assertIn('if MQTTConfig.reporting { MQTTReporter.shared.clearGPU() }', path)
        self.assertEqual(callback.count('MQTTReporter.shared.set('), 1)
        self.assertEqual(callback.count('MQTTReporter.shared.clearGPU()'), 3)

    def test_remote_decodes_validates_and_threads_gpu(self):
        self.assertIn('let gpu_percent: Double?', self.mqtt)
        self.assertIn('public struct RemoteModules: Codable', self.main)
        self.assertIn('public let gpu: Double?', self.main)
        self.assertIn('value.metrics?.gpu_percent.flatMap { gpu -> Double? in', self.mqtt)
        self.assertIn('guard gpu.isFinite, gpu >= 0, gpu <= 100 else { return nil }', self.mqtt)
        self.assertIn('return min(max(gpu / 100, 0), 1)', self.mqtt)
        calls = []
        for path in ROOT.rglob('*.swift'):
            source = path.read_text()
            for match in re.finditer(r'\bRemoteModules\s*\(', source):
                start = end = match.end()
                depth = 1
                while depth and end < len(source):
                    depth += (source[end] == '(') - (source[end] == ')')
                    end += 1
                self.assertEqual(depth, 0, str(path))
                call = source[start:end - 1]
                self.assertRegex(call, r'\bgpu\s*:', str(path))
                calls.append(call)
        self.assertTrue(calls)
        self.assertIn('gpu: gpu)', self.mqtt)

    def test_optional_tooltip_gpu_immediately_follows_load(self):
        details = self.main.split('public var details: String {', 1)[1].split('public struct RemoteModules', 1)[0]
        self.assertIn('if let load = self.modules?.load {\n'
                      '            lines.append("\\(localizedString("Load average")) (1m): \\(String(format: "%.2f", load))")\n'
                      '        }\n'
                      '        if let gpu = self.modules?.gpu {\n'
                      '            lines.append("\\(localizedString("GPU")): \\(Int((gpu * 100).rounded()))%")\n'
                      '        }', details)
        labels = ['Network', 'Load average', 'GPU', 'Disk', 'RAM', 'Uptime']
        positions = [details.index(f'localizedString("{label}")') for label in labels]
        self.assertEqual(positions, sorted(positions))
        for locale in ['en', 'zh-Hans', 'zh-Hant']:
            strings = (ROOT / f'Stats/Supporting Files/{locale}.lproj/Localizable.strings').read_text()
            self.assertEqual(len(re.findall(r'^"GPU"\s*=', strings, re.M)), 1, locale)


if __name__ == '__main__':
    unittest.main()
