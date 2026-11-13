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

    def test_installer_latest_and_tagged_downloads_use_fork(self):
        script = (ROOT / "Kit/scripts/install.sh").read_text()
        repository = re.search(r'^REPO="([^"]+)"$', script, re.MULTILINE).group(1)
        self.assertEqual(repository, REPOSITORY)
        urls = re.findall(r'^\s*URL="([^"]+)"$', script, re.MULTILINE)
        self.assertEqual([url.replace('$REPO', repository) for url in urls], [
            f'https://github.com/{REPOSITORY}/releases/latest/download/Stats.dmg',
            f'https://github.com/{REPOSITORY}/releases/download/v$VERSION/Stats.dmg',
        ])

    def test_documented_downloads_use_fork(self):
        readme = (ROOT / "README.md").read_text()
        self.assertNotIn('https://github.com/exelban/stats/releases', readme)
        self.assertNotIn('https://cdn.mac-stats.com/install.sh', readme)
        self.assertIn(f'https://github.com/{REPOSITORY}/releases/latest/download/Stats.dmg', readme)
        self.assertIn(f'https://raw.githubusercontent.com/{REPOSITORY}/master/Kit/scripts/install.sh', readme)

    def test_release_asset_and_signing_requirements_remain(self):
        updater = (ROOT / "Kit/plugins/Updater.swift").read_text()
        self.assertIn('jsonArray["tag_name"] as? String', updater)
        self.assertIn('$0["name"] as? String == "\\(self.appName).dmg"', updater)
        self.assertIn('asset["browser_download_url"] as? String', updater)
        self.assertIn('self.validateAppSignature(at: mountedApp)', updater)
        self.assertIn('SecStaticCodeCheckValidity(code, flags, nil)', updater)
        self.assertIn('if selfTeam != dmgTeam', updater)


if __name__ == "__main__":
    unittest.main()
