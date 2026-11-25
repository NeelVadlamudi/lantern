"""Tests for scripts/check_lamp_window.py: the window gap check that runs after every build.

Run: python -m unittest discover -s scripts/tests
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

import duckdb

SCRIPT = Path(__file__).resolve().parents[1] / "check_lamp_window.py"
SEP9 = date(2026, 9, 9)
LAST = date(2026, 10, 31)


def make(path, staged_days, trip_days):
    con = duckdb.connect(str(path))
    con.execute("create schema staging; create schema marts")
    con.execute("create table staging.stg_lamp__subway_trip_stops (service_date date, trip_id varchar)")
    con.execute("create table marts.fct_trips (service_date date, trip_id varchar)")
    con.executemany("insert into staging.stg_lamp__subway_trip_stops values (?, 't')", [[d] for d in staged_days])
    con.executemany("insert into marts.fct_trips values (?, 't')", [[d] for d in trip_days])
    con.close()


class WindowGapCheck(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = Path(self.dir.name) / "w.duckdb"
        self.window = [LAST - timedelta(days=i) for i in range(90)]  # Aug 3 - Oct 31, as dim_dates

    def tearDown(self):
        self.dir.cleanup()

    def run_check(self, allowed=(), *extra, gaps=None):
        lst = Path(self.dir.name) / "allowed.txt"
        lst.write_text("# test list\n" + "".join(f"{d} genuine gap\n" for d in allowed))
        args = [sys.executable, str(SCRIPT), str(self.db), *extra]
        if gaps is not None:
            gpath = Path(self.dir.name) / "gaps.json"
            gpath.write_text(json.dumps(gaps))
            args += ["--gaps-json", str(gpath)]
        return subprocess.run(args, capture_output=True, text=True,
                              env=dict(os.environ, LAMP_ALLOWED_GAPS=str(lst)))

    def without_sep9(self):
        return [d for d in self.window if d != SEP9]

    def test_full_window_passes(self):
        make(self.db, self.window, self.window)
        out = self.run_check()
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertNotIn("::error::", out.stdout)
        self.assertIn("window 2026-08-03 to 2026-10-31 (90 dates): 90 with trips", out.stdout)

    def test_missing_sep9_fails(self):
        make(self.db, self.without_sep9(), self.without_sep9())
        out = self.run_check()
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("::error::Missing service dates in the 90-day window: 2026-09-09 (no staging rows)", out.stdout)

    def test_missing_sep9_on_allowed_list_passes_with_notice(self):
        make(self.db, self.without_sep9(), self.without_sep9())
        out = self.run_check([SEP9])
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertNotIn("::error::", out.stdout)
        self.assertIn("::notice::Known upstream LAMP gap (on the allowed-gap list): 2026-09-09", out.stdout)

    def test_staged_but_not_in_fct_trips_fails(self):
        make(self.db, self.window, self.without_sep9())
        out = self.run_check()
        self.assertEqual(out.returncode, 1)
        self.assertIn("2026-09-09 (in staging, not in fct_trips)", out.stdout)

    def test_expected_days_come_from_the_calendar_not_the_loaded_range(self):
        # Only the last 10 days loaded (as if the build read just those files): the other 80
        # calendar dates of the window are still expected.
        make(self.db, self.window[:10], self.window[:10])
        out = self.run_check()
        self.assertEqual(out.returncode, 1)
        self.assertIn("90 dates): 10 with trips", out.stdout)
        self.assertIn("2026-08-03 (no staging rows)", out.stdout)

    def test_missing_first_day_fails(self):
        days = [d for d in self.window if d != self.window[-1]]  # Aug 3, the window's first date
        make(self.db, days, days)
        out = self.run_check()
        self.assertEqual(out.returncode, 1)
        self.assertIn("2026-08-03 (no staging rows)", out.stdout)

    def test_missing_warehouse_or_tables_fails_cleanly(self):
        out = self.run_check()
        self.assertEqual(out.returncode, 1)
        self.assertIn("::error::No warehouse at", out.stderr)
        duckdb.connect(str(self.db)).close()
        out = self.run_check()
        self.assertEqual(out.returncode, 1)
        self.assertIn("has no staging.stg_lamp__subway_trip_stops or marts.fct_trips", out.stderr)
        self.assertNotIn("Traceback", out.stderr)

    def test_window_days_option(self):
        make(self.db, [LAST, LAST - timedelta(days=2)], [LAST, LAST - timedelta(days=2)])
        out = self.run_check((), "--window-days", "3")
        self.assertEqual(out.returncode, 1)
        self.assertIn("2026-10-30 (no staging rows)", out.stdout)

    def gaps(self, not_published=(), published_empty=()):
        return {"list_source": "index.csv", "latest_published": str(LAST),
                "not_published": [str(d) for d in not_published],
                "published_empty": [str(d) for d in published_empty]}

    def without(self, *days):
        return [d for d in self.window if d not in days]

    def test_never_published_old_date_warns_and_passes(self):
        old = date(2026, 10, 20)  # 11 days before the window's end: past the grace window
        make(self.db, self.without(old), self.without(old))
        out = self.run_check(gaps=self.gaps(not_published=[old]))
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertNotIn("::error::", out.stdout)
        self.assertIn("::warning::", out.stdout)
        self.assertIn("2026-10-20", out.stdout)
        self.assertIn("newest service date MBTA has published: 2026-10-31", out.stdout)

    def test_never_published_recent_date_still_fails(self):
        recent = date(2026, 10, 30)  # one day before the window's end: may still be on its way
        make(self.db, self.without(recent), self.without(recent))
        out = self.run_check(gaps=self.gaps(not_published=[recent]))
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("::error::Missing service dates in the 90-day window: 2026-10-30 (no staging rows)", out.stdout)

    def test_published_empty_date_still_fails_loud(self):
        # MBTA did publish the day (an empty file): losing its rows is our problem, not a gap
        # the index summary can excuse. Only the allowed-gap list can excuse it.
        make(self.db, self.without_sep9(), self.without_sep9())
        out = self.run_check(gaps=self.gaps(published_empty=[SEP9]))
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("2026-09-09 (no staging rows)", out.stdout)

    def test_published_date_missing_with_gaps_file_still_fails(self):
        make(self.db, self.without_sep9(), self.without_sep9())
        out = self.run_check(gaps=self.gaps())
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("2026-09-09 (no staging rows)", out.stdout)


if __name__ == "__main__":
    unittest.main()
