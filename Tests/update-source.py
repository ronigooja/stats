#!/usr/bin/env python3
"""Run with python3 Tests/update-source.py; static checks, no Apple build required."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "ronigooja/stats"


class UpdateSourceTests(unittest.TestCase):
    def test_app_checks_only_fork_github_releases(self):
        app = (ROOT / "Stats/AppDelegate.swift").read_text()
        updater = (ROOT / "Kit/plugins/Updater.swift").read_text()
        self.assertIn(f'let updater = Updater(github: "{REPOSITORY}")', app)
        self.assertIn('https://api.github.com/repos/\\(github)/releases/latest', updater)
        self.assertEqual(re.findall(r'self\.fetchRelease\(uri: ([^)]+)\)', updater), ['self.github'])
        self.assertNotIn('api.mac-stats.com', app + updater)
        self.assertNotIn('exelban/stats', app + updater)
        self.assertNotIn('private let server:', updater)

    def test_changelog_uses_fork_release_tag(self):
        view = (ROOT / "Stats/Views/Update.swift").read_text()
        self.assertIn(f'https://github.com/{REPOSITORY}/releases/tag/\\(version.latest)', view)
        self.assertNotIn('exelban/stats', view)

    def test_documented_downloads_use_fork(self):
        readme = (ROOT / "README.md").read_text()
        self.assertNotIn('https://github.com/exelban/stats/releases', readme)
        self.assertNotIn('Kit/scripts/install.sh', readme)
        self.assertNotIn('System Stats account', readme)
        self.assertIn(f'https://github.com/{REPOSITORY}/releases/latest/download/Stats.dmg', readme)

    def test_release_lookup_does_not_require_assets(self):
        updater = (ROOT / "Kit/plugins/Updater.swift").read_text()
        fetch = updater.split('private func fetchRelease', 1)[1].split('public func download', 1)[0]
        self.assertIn('jsonArray["tag_name"] as? String', updater)
        self.assertIn('jsonArray["html_url"] as? String', fetch)
        self.assertIn(f'https://github.com/{REPOSITORY}/releases/tag/\\(lastVersion)', fetch)
        self.assertNotIn('assets', fetch)
        self.assertNotIn('.dmg', fetch)
        self.assertIn('statusCode == 404', fetch)
        self.assertIn('completion(nil, "No releases available")', fetch)
        self.assertLess(fetch.index('statusCode == 404'), fetch.index('JSONSerialization'))

    def test_manual_check_always_answers(self):
        updater = (ROOT / "Kit/plugins/Updater.swift").read_text()
        check = updater.split('public func check', 1)[1].split('private func fetchRelease', 1)[0]
        self.assertIn('"No releases available"', check)
        self.assertIn('newest: false', check)
        action = (ROOT / "Stats/Views/AppSettings.swift").read_text().split('@objc private func updateAction()', 1)[1].split('@objc private func toggleUpdateInterval', 1)[0]
        self.assertGreaterEqual(action.count('showAlert('), 2)

    def test_remote_settings_page_scrolls(self):
        window = (ROOT / "Kit/module/window.swift").read_text()
        branch = window.split('if self.config.name == "Remote" {', 1)[1].split('var labels', 1)[0]
        self.assertIn('ScrollableStackView()', branch)
        self.assertIn('return scrollView', branch)

    def test_download_button_opens_release_in_browser(self):
        view = (ROOT / "Stats/Views/Update.swift").read_text()
        action = view.split('@objc private func download()', 1)[1].split('private func downloadAndInstallLegacy', 1)[0]
        self.assertIn('downloadButton.action = #selector(self.download)', view)
        self.assertIn('self.version?.url', action)
        self.assertIn('NSWorkspace.shared.open(url)', action)
        self.assertIn('self.close()', action)
        self.assertNotIn('updater.download', action)
        self.assertNotIn('updater.install', action)
        for name in ['Stats/AppDelegate.swift', 'Stats/helpers.swift']:
            source = (ROOT / name).read_text()
            self.assertNotIn('updater.download(', source)
            self.assertNotIn('updater.install(', source)

    def test_legacy_installer_retains_signature_checks(self):
        updater = (ROOT / "Kit/plugins/Updater.swift").read_text()
        self.assertIn('self.validateAppSignature(at: mountedApp)', updater)
        self.assertIn('SecStaticCodeCheckValidity(code, flags, nil)', updater)
        self.assertIn('if selfTeam != dmgTeam', updater)

    def test_leading_v_version_comparison(self):
        helper = (ROOT / 'Kit/helpers.swift').read_text().split('public func isNewestVersion', 1)[1]
        self.assertIn('currentVersion.replacingOccurrences(of: "v", with: "")', helper)
        self.assertIn('latestVersion.replacingOccurrences(of: "v", with: "")', helper)

        # Small port of the helper's non-beta branch, not a Swift runtime test.
        def newer(current, latest):
            def components(value):
                parts = value.replace('v', '').split('.')
                return [int(parts[i]) if i < len(parts) else 0 for i in range(3)]
            c, n = components(current), components(latest)
            return (n[0] > c[0] or
                    (n[1] > c[1] and n[0] >= c[0]) or
                    (n[2] > c[2] and n[1] >= c[1] and n[0] >= c[0]))

        for current, latest, expected in [
            ('0.1.0', 'v0.1.0', False), ('v0.1.0', '0.1.0', False),
            ('0.1.0', 'v0.1.1', True), ('v0.1.0', '0.2.0', True),
            ('v0.2.0', 'v0.1.9', False), ('v0.9.9', 'v1.0.0', True),
            ('v1.0.0', 'v0.99.99', False), ('v1.0', '1.0.1', True),
        ]:
            with self.subTest(current=current, latest=latest):
                self.assertEqual(newer(current, latest), expected)


if __name__ == "__main__":
    unittest.main()
