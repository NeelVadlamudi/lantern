import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from site_freshness import check  # noqa: E402

NOW = datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc)


def board(ts):
    return {"build": {"generated_at_utc": ts}}


class SiteFreshnessTest(unittest.TestCase):
    def test_fresh_build_passes(self):
        self.assertTrue(check(board("2026-11-01T12:00:00.000000Z"), NOW)[0])

    def test_oct29_build_fails_and_names_date(self):
        ok, msg = check(board("2026-10-29T17:31:48.786208Z"), NOW)
        self.assertFalse(ok)
        self.assertIn("2026-10-29", msg)

    def test_just_over_limit_fails(self):
        ts = (NOW - timedelta(hours=26, minutes=1)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        self.assertFalse(check(board(ts), NOW)[0])

    def test_missing_or_bad_timestamp_fails(self):
        self.assertFalse(check({}, NOW)[0])
        self.assertFalse(check(board("yesterday"), NOW)[0])


if __name__ == "__main__":
    unittest.main()
