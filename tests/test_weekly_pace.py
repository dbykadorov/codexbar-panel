"""Test the shipped embedded script without running the installer or provider CLIs."""
import contextlib
import datetime
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

SOURCE = (Path(__file__).resolve().parents[1] / 'install.sh').read_text().split("<<'PANEL_EOF'\n", 1)[1].split('\nPANEL_EOF', 1)[0]


class WeeklyPaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.module = types.ModuleType('panel_usage')
        with patch.dict('os.environ', {'HOME': self.temp.name}):
            exec(compile(SOURCE, 'panel-usage', 'exec'), self.module.__dict__)
        self.now = 1800000000
        self.week = 7 * 86400

    def reset(self, remaining):
        return datetime.datetime.fromtimestamp(self.now + remaining, datetime.timezone.utc).isoformat()

    def test_behind_and_forecast(self):
        p = self.module.weekly_pace(85, self.reset(.22 * self.week), now=self.now)
        self.assertAlmostEqual(p['reserve'], -7)
        self.assertEqual(self.module.pace_label(p), '-7pp')
        self.assertAlmostEqual(p['exhaustion'], .78 * self.week * 15 / 85)
        self.assertLess(p['exhaustion'], p['remaining'])

    def test_ahead_zero_and_exhausted(self):
        p = self.module.weekly_pace(10, self.reset(self.week / 2), now=self.now)
        self.assertEqual(self.module.pace_label(p), '+40pp')
        self.assertGreater(p['exhaustion'], p['remaining'])
        self.assertIsNone(self.module.weekly_pace(0, self.reset(1000), now=self.now)['exhaustion'])
        self.assertEqual(self.module.weekly_pace(100, self.reset(1000), now=self.now)['exhaustion'], 0)

    def test_invalid_and_reset_boundary(self):
        for used, reset, minutes in [(20, self.reset(0), 10080), (20, self.reset(self.week), 10080),
                                     (None, self.reset(100), 10080), (float('nan'), self.reset(100), 10080),
                                     (101, self.reset(100), 10080), (20, 'bad', 10080),
                                     (20, '2026-11-06T00:00:00', 10080), (20, self.reset(100), None)]:
            self.assertIsNone(self.module.weekly_pace(used, reset, minutes, now=self.now))

    def test_promoted_weekly_and_stale(self):
        data = self.module.parse({'usage': {'secondary': {'usedPercent': 85, 'resetsAt': self.reset(.22 * self.week)}}})
        with patch.object(self.module.time, 'time', return_value=self.now):
            self.assertIn('-7pp', self.module.live_body(data))
            ET.fromstring('<root>' + self.module.live_body(data) + '</root>')
            self.assertNotIn('pp', self.module.seg('Cx', '#fff', data, False))
            self.assertIn('[stale]', self.module.seg('Cx', '#fff', data, False))
        self.assertNotIn('pp', self.module.live_body({'sp': 10}))  # old cache

    def test_claude_session_and_codex_unchanged(self):
        usage = {'primary': {'usedPercent': 60, 'resetsAt': self.reset(9000)},
                 'secondary': {'usedPercent': 85, 'resetsAt': self.reset(.22 * self.week)}}
        with patch.object(self.module.time, 'time', return_value=self.now):
            claude = self.module.parse({'provider': 'claude', 'usage': usage})
            self.assertIn('-10pp', self.module.live_body(claude))
            self.assertEqual(self.module.live_body(claude).count('pp'), 2)
            codex = self.module.parse({'provider': 'codex', 'usage': usage})
            self.assertEqual(self.module.live_body(codex).count('pp'), 1)
            self.assertNotIn('pp', self.module.seg('Cl', '#fff', claude, False))
            ET.fromstring('<root>' + self.module.live_body(claude) + '</root>')
        payload = [{'provider': 'claude', 'usage': usage}]
        output = io.StringIO()
        result = types.SimpleNamespace(returncode=0, stdout=json.dumps(payload))
        with patch.object(self.module.subprocess, 'run', return_value=result), patch.object(self.module.time, 'time', return_value=self.now), contextlib.redirect_stdout(output):
            self.module.provider_json('claude')
        details = json.loads(output.getvalue())[0]['usage']['details']
        self.assertEqual([d['title'] for d in details], ['5h pace', 'Weekly pace'])
        self.assertEqual(details[0]['rows'][0]['value'], '-10pp')
        self.assertIn('1h 40m', details[0]['rows'][1]['value'])

    def test_json_details_and_filter(self):
        payload = [{'provider': 'claude', 'usage': {'secondary': {'usedPercent': 85, 'resetsAt': self.reset(.22 * self.week)},
                    'extraRateWindows': [], 'details': [{'title': 'Existing', 'rows': []}]}}]
        result = types.SimpleNamespace(returncode=0, stdout=json.dumps(payload))
        output = io.StringIO()
        with patch.object(self.module.subprocess, 'run', return_value=result), patch.object(self.module.time, 'time', return_value=self.now), contextlib.redirect_stdout(output):
            self.module.provider_json('claude')
        usage = json.loads(output.getvalue())[0]['usage']
        self.assertNotIn('extraRateWindows', usage)
        self.assertEqual(usage['details'][0]['title'], 'Existing')
        self.assertEqual(usage['details'][1]['rows'][0]['value'], '-7pp')
        self.assertIn('Runs out in', usage['details'][1]['rows'][1]['value'])


if __name__ == '__main__':
    unittest.main()
