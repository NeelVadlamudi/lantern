"""Tests for scripts/fallback_alarm.sh: a run that serves the last good site must fail and name
the served build date; a good run must stay green.

Run: python -m unittest discover -s scripts/tests
"""
import json
import os
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "fallback_alarm.sh")
HEALTH = {"runs": [
    {"run_date": "2026-10-31", "status": "fail"},
    {"run_date": "2026-10-30", "status": "fail"},
    {"run_date": "2026-10-29", "status": "pass"},
    {"run_date": "2026-10-28", "status": "pass"},
]}


class FallbackAlarm(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.health = os.path.join(self.dir.name, "previous_health.json")
        with open(self.health, "w") as f:
            json.dump(HEALTH, f)
        self.summary = os.path.join(self.dir.name, "summary.md")

    def tearDown(self):
        self.dir.cleanup()

    def run_alarm(self, good, restored, health=None):
        env = dict(os.environ, GITHUB_STEP_SUMMARY=self.summary)
        return subprocess.run(["bash", SCRIPT, good, health or self.health, restored],
                              capture_output=True, text=True, env=env)

    def test_good_build_stays_green(self):
        r = self.run_alarm("true", "false")
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("::error", r.stdout)

    def test_fallback_one_day_after_last_pass_fails(self):
        # The Oct 30 case: last pass yesterday, which used to exit 0 with only a warning.
        r = self.run_alarm("false", "true")
        self.assertEqual(r.returncode, 1)
        self.assertIn("::error", r.stdout)
        self.assertIn("2026-10-29", r.stdout)
        with open(self.summary) as f:
            self.assertIn("2026-10-29", f.read())

    def test_empty_outcome_counts_as_failed(self):
        # The outcome step itself did not run: good is empty, never green.
        r = self.run_alarm("", "true")
        self.assertEqual(r.returncode, 1)

    def test_no_saved_site_fails(self):
        r = self.run_alarm("false", "false")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no last good site", r.stdout)

    def test_missing_health_log_still_fails(self):
        r = self.run_alarm("false", "true", health=os.path.join(self.dir.name, "nope.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("unknown date", r.stdout)


if __name__ == "__main__":
    unittest.main()
