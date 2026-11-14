#!/usr/bin/env python3
"""Run with python3 Tests/version.py; Swift algorithm port and source checks, no build."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
INT_MIN, INT_MAX = -(2 ** 63), 2 ** 63 - 1


def swift_int(value):
    if not re.fullmatch(r'[+-]?[0-9]+', value):
        return None
    number = int(value)
    return number if INT_MIN <= number <= INT_MAX else None


def parse_version(value, fork=True):
    """Mirror isNewestVersion parsing, including Swift split's omitted empty fields."""
    number = value.replace('v', '')
    revision = 0
    if fork and '-roni-' in number:
        number, suffix = number.rsplit('-roni-', 1)
        if re.fullmatch(r'[0-9]+', suffix):
            revision = swift_int(suffix) or 0
    # condenseWhitespace removes empty whitespace/newline components, then joins with spaces.
    parts = [part for part in ' '.join(number.split()).split('.') if part]
    components = [swift_int(parts[i]) or 0 if i < len(parts) else 0 for i in range(3)]
    beta = None
    if parts and '-' in parts[-1]:
        patch = [part for part in parts[-1].split('-') if part]
        if patch:
            components[2] = swift_int(patch[0]) or 0
            beta = swift_int(patch[-1].replace('beta', '')) or 0
    return (*components, beta, revision)


def is_newest_version(current_version, latest_version, fork=True):
    """Faithful port; keep the legacy beta branches unchanged, even their quirks."""
    cm, cn, cp, cb, cr = parse_version(current_version, fork)
    lm, ln, lp, lb, lr = parse_version(latest_version, fork)
    if cb is None and lb is None:
        if fork:
            if lm != cm:
                return lm > cm
            if ln != cn:
                return ln > cn
            if lp != cp:
                return lp > cp
            return lr > cr
        if lm > cm:
            return True
        if ln > cn and lm >= cm:
            return True
        if lp > cp and ln >= cn and lm >= cm:
            return True
    if cb is not None and lb is None:
        if lm > cm:
            return True
        if ln > cn and lm >= cm:
            return True
        if lp >= cp and ln >= cn and lm >= cm:
            return True
    if cb is not None and lb is not None:
        if lm > cm:
            return True
        if ln > cn and lm >= cm:
            return True
        if lp >= cp and ln >= cn and lm >= cm:
            return True
        if lb > cb and lp >= cp and ln >= cn and lm >= cm:
            return True
    return False


CASES = [
    ('v3.0.26', 'v3.0.26-roni-1', True),
    ('v3.0.26-roni-1', 'v3.0.26-roni-2', True),
    ('v3.0.26-roni-2', 'v3.0.26-roni-10', True),
    ('v3.0.26-roni-2', 'v3.0.26-roni-2', False),
    ('v3.0.26-roni-2', 'v3.0.26-roni-1', False),
    ('v3.0.26-roni-5', 'v3.0.27', True),
    ('v3.0.27', 'v3.0.26-roni-9', False),
    ('v3.0.26-roni-1', 'v3.0.26', False),
    ('v3.0.26-roni-1', 'v3.1.0', True),
    ('v3.0.26-roni-1', 'v4.0.0', True),
    ('v3.1.0-roni-1', 'v3.0.99', False),
    ('v3.0.8-beta1', 'v3.0.8', True),
    ('v3.0.8', 'v3.0.9', True),
    ('v3.0.9', 'v3.0.8', False),
    ('v3.0.8-beta1', 'v3.0.8-beta2', True),
    ('v3.0.8', 'v3.0.9-beta1', False),
    ('v3.0.8-beta1', 'v3.0.7', False),
    # Preserve the existing implementation, not the contradictory Tests/Kit.swift assertions.
    ('v3.0.8-beta2', 'v3.0.8-beta1', True),
    ('v3.0.8-beta1', 'v3.0.8-beta1', True),
    ('v3.0.8-beta1-roni-1', 'v3.0.8-beta2-roni-2', True),
    ('v3.0.8-roni-1', 'v3.0.9-beta1-roni-2', False),
    ('v3', 'v3.0.0', False),
    ('v3', 'v3.0.1', True),
    ('v3.0', 'v3.0.0', False),
    ('', '', False),
    ('3.0.26-roni-1', 'v3.0.26-roni-2', True),
    ('v3.0.26-roni-0002', 'v3.0.26-roni-10', True),
]


class VersionTests(unittest.TestCase):
    def test_comparison_cases(self):
        for current, latest, expected in CASES:
            with self.subTest(current=current, latest=latest):
                self.assertEqual(is_newest_version(current, latest), expected)

    def test_invalid_revisions_are_zero_not_beta(self):
        for suffix in ['', 'x', '0', '-1', '+1', '1x', '1-beta2', str(INT_MAX + 1)]:
            malformed = 'v3.0.26-roni-' + suffix
            with self.subTest(suffix=suffix):
                self.assertEqual(parse_version(malformed), (3, 0, 26, None, 0))
                for current, latest, expected in [
                    ('v3.0.26', malformed, False),
                    (malformed, 'v3.0.26', False),
                    (malformed, 'v3.0.26-roni-1', True),
                    ('v3.0.26-roni-1', malformed, False),
                    (malformed, 'v3.0.27', True),
                ]:
                    self.assertEqual(is_newest_version(current, latest), expected)

    def test_no_fork_behavior_matches_original_algorithm(self):
        versions = ['', 'v3', 'v3.0', '3.0.8', 'v3.0.8-beta1', 'v3.0.8-beta2',
                    'v3.0.8-beta', 'v3.0.8-other', 'v3.0.9-beta1', 'v3.0.9',
                    'v3.1.0', 'v2.99.99', 'v4.0.0']
        for current in versions:
            for latest in versions:
                with self.subTest(current=current, latest=latest):
                    self.assertEqual(is_newest_version(current, latest),
                                     is_newest_version(current, latest, fork=False))

    def test_swift_source_keeps_fork_parsing_before_beta_parsing(self):
        source = (ROOT / 'Kit/helpers.swift').read_text()
        helper = source.split('public func isNewestVersion', 1)[1].split('public func showNotification', 1)[0]
        updater = (ROOT / 'Kit/plugins/Updater.swift').read_text()
        self.assertIn('var revision: Int = 0', updater)
        for fragment in ['number.range(of: "-roni-", options: .backwards)',
                         'number = String(number[..<range.lowerBound])',
                         'suffix.allSatisfy({ $0 >= "0" && $0 <= "9" })',
                         'let revision = Int(suffix), revision > 0 else { return 0 }',
                         'current.revision = currentRevision',
                         'latest.revision = latestRevision',
                         'return latest.revision > current.revision']:
            self.assertIn(fragment, helper)
        self.assertLess(helper.index('forkRevision(&currentNumber)'), helper.index('let currentArray'))
        self.assertLess(helper.index('forkRevision(&latestNumber)'), helper.index('let latestArray'))
        self.assertLess(helper.index('let latestArray'), helper.index('patch.contains("-")'))

    def test_update_display_retains_original_tag(self):
        updater = (ROOT / 'Kit/plugins/Updater.swift').read_text()
        view = (ROOT / 'Stats/Views/Update.swift').read_text()
        self.assertIn('latest: result.tag,', updater)
        self.assertIn('currentVersion.stringValue = version.current', view)
        self.assertIn('latestVersion.stringValue = version.latest', view)
        self.assertIn('releases/tag/\\(version.latest)', view)


if __name__ == '__main__':
    unittest.main()
