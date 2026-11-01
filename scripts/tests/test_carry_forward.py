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


def make(path, staged, reads):
    """staged: {date: rows}; reads: {date: num_rows} as the manifest recorded them."""
    con = duckdb.connect(str(path))
    con.execute("create schema staging")
    con.execute("create table staging.stg_lamp__subway_trip_stops (service_date date, trip_id varchar, _loaded_at timestamp)")
    con.execute("create table staging.lamp_file_reads (service_date date, last_modified_utc timestamp, "
                "file_url varchar, num_rows bigint, checked_at timestamp)")
    for d, n in staged.items():
        for i in range(n):
            con.execute("insert into staging.stg_lamp__subway_trip_stops values (?, ?, timestamp '2026-10-01')", [d, f"t{i}"])
    for d, n in reads.items():
        con.execute("insert into staging.lamp_file_reads values (?, null, 'f', ?, null)", [d, n])
    con.close()


D1, D2, D3 = date(2026, 9, 8), date(2026, 9, 9), date(2026, 9, 10)


class CarryForward(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.new = Path(self.dir.name) / "new.duckdb"
        self.prev = Path(self.dir.name) / "prev.duckdb"

    def tearDown(self):
        self.dir.cleanup()

    def run_cli(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.new), str(self.prev)],
                              capture_output=True, text=True)

    def test_republished_empty_without_previous_fails(self):
        make(self.new, {D1: 2, D3: 2}, {D1: 2, D2: 0, D3: 2})
        out = self.run_cli()
        self.assertEqual(out.returncode, 1)
        self.assertIn("::error::No rows for 2026-09-09", out.stdout)

    def test_previous_without_the_day_fails(self):
        make(self.new, {D1: 2, D3: 2}, {D1: 2, D2: 0, D3: 2})
        make(self.prev, {D1: 2}, {})
        out = self.run_cli()
        self.assertEqual(out.returncode, 1)
        self.assertIn("2026-09-09", out.stdout)

    def test_carry_restores_staging_rows_only(self):
        make(self.new, {D1: 2, D3: 2}, {D1: 2, D2: 0, D3: 2})
        make(self.prev, {D1: 5, D2: 3}, {})
        out = self.run_cli()
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertNotIn("::error::", out.stdout)
        con = duckdb.connect(str(self.new), read_only=True)
        counts = dict(con.execute("select service_date, count(*) from staging.stg_lamp__subway_trip_stops group by 1").fetchall())
        tables = con.execute("select count(*) from information_schema.tables").fetchone()[0]
        con.close()
        self.assertEqual(counts, {D1: 2, D2: 3, D3: 2})
        self.assertEqual(tables, 2)

    def test_never_published_day_is_allowed_notice(self):
        make(self.new, {D1: 2, D3: 2}, {D1: 2, D3: 2})
        out = self.run_cli()
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn("::notice::LAMP never published (upstream gap, allowed): 2026-09-09", out.stdout)

    def test_no_missing_days(self):
        make(self.new, {D1: 1, D2: 1}, {D1: 1, D2: 1})
        self.assertEqual(carry_forward(str(self.new), str(self.prev)), ([], [], []))


if __name__ == "__main__":
    unittest.main()
