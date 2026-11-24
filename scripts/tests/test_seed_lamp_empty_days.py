"""Tests for scripts/seed_lamp_empty_days.py: saving the staging rows of published-empty days
and putting them back into a fresh warehouse.

Run: python -m unittest discover -s scripts/tests
"""
import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

import duckdb

SCRIPT = Path(__file__).resolve().parents[1] / "seed_lamp_empty_days.py"
sys.path.insert(0, str(SCRIPT.parent))
from seed_lamp_empty_days import apply, export  # noqa: E402

SEP9 = date(2026, 9, 9)
SEP10 = date(2026, 9, 10)


def make(path, staged):
    """staged: {date: rows} in staging.stg_lamp__subway_trip_stops."""
    con = duckdb.connect(str(path))
    con.execute("create schema staging")
    con.execute("create table staging.stg_lamp__subway_trip_stops (service_date date, trip_id varchar, _loaded_at timestamp)")
    for d, n in staged.items():
        for i in range(n):
            con.execute("insert into staging.stg_lamp__subway_trip_stops values (?, ?, timestamp '2026-10-01')", [d, f"t{i}"])
    con.close()


def counts(path):
    con = duckdb.connect(str(path), read_only=True)
    out = dict(con.execute("select service_date, count(*) from staging.stg_lamp__subway_trip_stops group by 1").fetchall())
    con.close()
    return out


class SeedEmptyDays(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.warm = Path(self.dir.name) / "warm.duckdb"
        self.fresh = Path(self.dir.name) / "fresh.duckdb"
        self.seed = Path(self.dir.name) / "lamp_empty_days.parquet"
        self.gaps = Path(self.dir.name) / "gaps.json"
        self.gaps.write_text(json.dumps({"published_empty": [str(SEP9)], "not_published": []}))

    def tearDown(self):
        self.dir.cleanup()

    def test_round_trip_restores_the_empty_day(self):
        make(self.warm, {SEP9: 3, SEP10: 2})
        saved = export(str(self.warm), str(self.gaps), str(self.seed))
        self.assertEqual(saved, [SEP9])
        self.assertTrue(self.seed.exists())

        make(self.fresh, {SEP10: 2})  # a cold warehouse: Sep 10 loaded, Sep 9 unrecoverable
        carried = apply(str(self.fresh), str(self.seed))
        self.assertEqual(carried, [SEP9])
        self.assertEqual(counts(self.fresh), {SEP9: 3, SEP10: 2})

    def test_export_with_no_rows_saves_nothing(self):
        make(self.warm, {SEP10: 2})
        saved = export(str(self.warm), str(self.gaps), str(self.seed))
        self.assertEqual(saved, [])
        self.assertFalse(self.seed.exists())

    def test_apply_without_a_seed_file_is_a_no_op(self):
        make(self.fresh, {SEP10: 2})
        self.assertEqual(apply(str(self.fresh), str(self.seed)), [])
        self.assertEqual(counts(self.fresh), {SEP10: 2})


if __name__ == "__main__":
    unittest.main()
