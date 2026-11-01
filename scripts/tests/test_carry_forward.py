"""Tests for scripts/carry_forward_lamp_days.py on small DuckDB files.

Run: python -m unittest discover -s scripts/tests
"""
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

import duckdb

SCRIPT = Path(__file__).resolve().parents[1] / "carry_forward_lamp_days.py"
sys.path.insert(0, str(SCRIPT.parent))
from carry_forward_lamp_days import carry_forward  # noqa: E402


def make(path, staged):
    """staged: {date: rows} in staging.stg_lamp__subway_trip_stops."""
    con = duckdb.connect(str(path))
    con.execute("create schema staging")
    con.execute("create table staging.stg_lamp__subway_trip_stops (service_date date, trip_id varchar, _loaded_at timestamp)")
    for d, n in staged.items():
        for i in range(n):
            con.execute("insert into staging.stg_lamp__subway_trip_stops values (?, ?, timestamp '2026-10-01')", [d, f"t{i}"])
    con.close()


D0, D1, D2, D3 = date(2026, 9, 7), date(2026, 9, 8), date(2026, 9, 9), date(2026, 9, 10)


class CarryForward(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.new = Path(self.dir.name) / "new.duckdb"
        self.prev = Path(self.dir.name) / "prev.duckdb"

    def tearDown(self):
        self.dir.cleanup()

    def counts(self):
        con = duckdb.connect(str(self.new), read_only=True)
        out = dict(con.execute("select service_date, count(*) from staging.stg_lamp__subway_trip_stops group by 1").fetchall())
        tables = con.execute("select count(*) from information_schema.tables").fetchone()[0]
        con.close()
        return out, tables

    def test_carry_restores_staging_rows_only(self):
        make(self.new, {D1: 2, D3: 2})
        make(self.prev, {D1: 5, D2: 3})
        self.assertEqual(carry_forward(str(self.new), str(self.prev), window_days=3), [D2])
        self.assertEqual(self.counts(), ({D1: 2, D2: 3, D3: 2}, 1))

    def test_carry_fills_window_days_before_the_first_loaded_date(self):
        # The window is calendar dates ending on the newest date, not the loaded range.
        make(self.new, {D2: 1, D3: 1})
        make(self.prev, {D0: 4, D1: 2})
        self.assertEqual(carry_forward(str(self.new), str(self.prev), window_days=3), [D1])
        self.assertEqual(self.counts()[0], {D1: 2, D2: 1, D3: 1})

    def test_previous_without_the_day_carries_nothing(self):
        make(self.new, {D1: 2, D3: 2})
        make(self.prev, {D1: 2})
        self.assertEqual(carry_forward(str(self.new), str(self.prev), window_days=3), [])

    def test_no_previous_warehouse_is_a_no_op(self):
        make(self.new, {D1: 2, D3: 2})
        self.assertEqual(carry_forward(str(self.new), str(self.prev), window_days=3), [])
        self.assertFalse(self.prev.exists())

    def test_no_missing_days(self):
        make(self.new, {D1: 1, D2: 1, D3: 1})
        make(self.prev, {D2: 9})
        self.assertEqual(carry_forward(str(self.new), str(self.prev), window_days=3), [])
        self.assertEqual(self.counts()[0], {D1: 1, D2: 1, D3: 1})

    def test_cli_writes_carried_count_and_exits_zero(self):
        make(self.new, {D1: 2, D3: 2})
        make(self.prev, {D2: 3})
        out_file = Path(self.dir.name) / "out.txt"
        out = subprocess.run([sys.executable, str(SCRIPT), str(self.new), str(self.prev), "--window-days", "3"],
                             capture_output=True, text=True, env=dict(os.environ, GITHUB_OUTPUT=str(out_file)))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("carried over: 2026-09-09", out.stdout)
        self.assertEqual(out_file.read_text(), "carried=1\n")


if __name__ == "__main__":
    unittest.main()
