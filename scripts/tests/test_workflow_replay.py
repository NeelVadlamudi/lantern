"""Replays the daily refresh's warehouse steps in workflow order on small synthetic data.

Runs the real run: blocks of .github/workflows/daily_refresh.yml, from "Set previous warehouse
aside" through "Decide what to publish" (restore, set aside, source freshness, build, replay,
carry-over, gap check, outcome), with the step if: conditions evaluated. dbt is a stub that acts
like dbt on the warehouse file: `source freshness` opens (and so creates) the DuckDB file at
MBTA_DUCKDB_PATH, and `build` loads the 90-day window when staging is empty, except
2026-09-09, which MBTA republished empty, then rebuilds marts.fct_trips from staging. The
network-only "LAMP file list" step is skipped and scripts/mirror_open_data.sh is stubbed.

REPLAY_REF=<git ref> replays that commit's workflow and scripts instead of the working tree
(REPLAY_REF=d63d44a fails: its source freshness step creates the warehouse file, the build
then takes the warehouse for a warm one, and the carry-over never runs).

Run: python -m unittest discover -s scripts/tests
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from datetime import date, timedelta
from pathlib import Path

import duckdb
import yaml

REPO = Path(__file__).resolve().parents[2]
LAST = date(2026, 10, 31)
WINDOW = [LAST - timedelta(days=i) for i in range(89, -1, -1)]
SEP9 = date(2026, 9, 9)

DBT_STUB = textwrap.dedent(f"""\
    #!{sys.executable}
    import os, sys, duckdb
    from datetime import date, timedelta
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    path = os.environ.get("MBTA_DUCKDB_PATH", "warehouse/mbta.duckdb")
    if args[:2] == ["source", "freshness"]:
        duckdb.connect(path).close()          # like dbt: opening the profile's path creates it
    elif args[0] == "build":
        con = duckdb.connect(path)
        con.execute("create schema if not exists staging; create schema if not exists marts")
        if not con.execute("select count(*) from information_schema.tables where table_schema = 'staging'"
                           " and table_name = 'stg_lamp__subway_trip_stops'").fetchone()[0]:
            con.execute("create table staging.stg_lamp__subway_trip_stops"
                        " (service_date date, trip_id varchar, _loaded_at timestamp)")
            days = [date(2026, 10, 31) - timedelta(days=i) for i in range(90)]
            con.executemany("insert into staging.stg_lamp__subway_trip_stops values (?, 'built', now())",
                            [[d] for d in days if d != date(2026, 9, 9)])   # file republished empty
        con.execute("create or replace table marts.fct_trips as"
                    " select distinct service_date, trip_id from staging.stg_lamp__subway_trip_stops")
        con.close()
        os.makedirs("out", exist_ok=True)
        open("out/board_data.json", "w").write("{{}}")
    """)


def make_warehouse(path, days, tag):
    con = duckdb.connect(str(path))
    con.execute("create schema staging; create schema marts")
    con.execute("create table staging.stg_lamp__subway_trip_stops (service_date date, trip_id varchar, _loaded_at timestamp)")
    con.executemany("insert into staging.stg_lamp__subway_trip_stops values (?, ?, timestamp '2026-10-29')",
                    [[d, tag] for d in days])
    con.execute("create table marts.fct_trips as select distinct service_date, trip_id from staging.stg_lamp__subway_trip_stops")
    con.close()


def evaluate(expr, steps, cwd):
    expr = re.sub(r"hashFiles\('([^']+)'\)", lambda m: repr("h" if (cwd / m.group(1)).exists() else ""), expr)

    def lookup(m):
        step = steps.get(m.group(1), {})
        if m.group(2) == "outcome":
            return repr(step.get("outcome", ""))
        return repr(step.get("outputs", {}).get(m.group(3), ""))
    expr = re.sub(r"steps\.([\w-]+)\.(outcome|outputs\.([\w-]+))", lookup, expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    return eval(expr, {}, {})


def replay(prev_days=None, warm_days=None, allowed=()):
    """Returns (steps, work dir). prev_days: a previous warehouse restored on a v4 miss;
    warm_days: a v4 warehouse restored."""
    work = Path(tempfile.mkdtemp(prefix="replay_"))
    ref = os.environ.get("REPLAY_REF")
    if ref:
        tar = subprocess.run(["git", "-C", str(REPO), "archive", ref, ".github", "scripts", "dbt_project.yml"],
                             capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", str(work)], input=tar, check=True)
    else:
        for p in (".github", "scripts"):
            shutil.copytree(REPO / p, work / p)
        shutil.copy(REPO / "dbt_project.yml", work)
    (work / "scripts/mirror_open_data.sh").write_text("#!/bin/sh\necho '{}'\n")
    (work / "scripts/lamp_allowed_gaps.txt").write_text("".join(f"{d} test gap\n" for d in allowed))
    bin_dir = work / "bin"
    bin_dir.mkdir()
    (bin_dir / "dbt").write_text(DBT_STUB)
    for f in (bin_dir / "dbt", work / "scripts/mirror_open_data.sh"):
        f.chmod(0o755)
    runner_temp = work / "runner_temp"
    runner_temp.mkdir()
    (work / "warehouse").mkdir()

    steps = {"warehouse": {"outputs": {"cache-matched-key": ""}}, "prev_warehouse": {"outputs": {"cache-matched-key": ""}}}
    if warm_days is not None:
        make_warehouse(work / "warehouse/mbta.duckdb", warm_days, "cached")
        steps["warehouse"]["outputs"]["cache-matched-key"] = "mbta-duckdb-v4-1"
    elif prev_days is not None:
        make_warehouse(work / "warehouse/mbta.duckdb", prev_days, "previous")
        steps["prev_warehouse"]["outputs"]["cache-matched-key"] = "mbta-duckdb-v3-1"

    wf = yaml.safe_load((work / ".github/workflows/daily_refresh.yml").read_text())
    job = next(j for j in wf["jobs"].values() if any(s.get("name") == "Set previous warehouse aside" for s in j["steps"]))
    names = [s.get("name") for s in job["steps"]]
    seq = job["steps"][names.index("Set previous warehouse aside"):names.index("Decide what to publish") + 1]
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", RUNNER_TEMP=str(runner_temp))
    env.pop("MBTA_DUCKDB_PATH", None)
    env.pop("LAMP_ALLOWED_GAPS", None)
    halted = False
    for i, step in enumerate(seq):
        sid = step.get("id", f"_{i}")
        if "run" not in step or step.get("name") == "LAMP file list":
            continue
        cond = step.get("if")
        if halted or (cond and not evaluate(cond, steps, work)):
            steps[sid] = {"outcome": "skipped", "outputs": {}}
            continue
        script = re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(evaluate(m.group(1), steps, work)).replace("True", "true")
                        .replace("False", "false"), step["run"])
        out_file = runner_temp / f"out_{i}"
        out_file.write_text("")
        r = subprocess.run(["bash", "-e", "-c", script], cwd=work, capture_output=True, text=True,
                           env=dict(env, GITHUB_OUTPUT=str(out_file), GITHUB_ENV=str(runner_temp / "env")))
        outputs = dict(line.split("=", 1) for line in out_file.read_text().splitlines() if "=" in line)
        steps[sid] = {"outcome": "success" if r.returncode == 0 else "failure", "outputs": outputs,
                      "log": r.stdout + r.stderr}
        if r.returncode and not step.get("continue-on-error"):
            halted = True
    return steps, work


def trip_dates(work):
    con = duckdb.connect(str(work / "warehouse/mbta.duckdb"), read_only=True)
    out = {r[0] for r in con.execute("select distinct service_date from marts.fct_trips").fetchall()}
    con.close()
    return out


class WorkflowReplay(unittest.TestCase):
    def tearDown(self):
        if getattr(self, "work", None):
            shutil.rmtree(self.work, ignore_errors=True)

    def describe(self, steps):
        return "\n".join(f"{k}: {v.get('outcome')} {v.get('outputs')}\n{v.get('log', '').strip()}" for k, v in steps.items())

    def test_cold_start_carries_sep9_from_previous_warehouse(self):
        steps, self.work = replay(prev_days=WINDOW)
        self.assertFalse((self.work / "warehouse/prev.duckdb").exists())
        self.assertIn(SEP9, trip_dates(self.work), self.describe(steps))
        self.assertEqual(steps["carry"]["outcome"], "success", self.describe(steps))
        self.assertEqual(steps["outcome"]["outputs"].get("good"), "true", self.describe(steps))

    def test_cold_start_without_previous_day_goes_red(self):
        steps, self.work = replay()
        self.assertNotIn(SEP9, trip_dates(self.work))
        self.assertEqual(steps["outcome"]["outputs"].get("good"), "false", self.describe(steps))

    def test_cold_start_without_previous_day_on_allowed_list_publishes(self):
        steps, self.work = replay(allowed=[SEP9])
        self.assertEqual(steps["outcome"]["outputs"].get("good"), "true", self.describe(steps))

    def test_warm_run_with_full_window_publishes(self):
        steps, self.work = replay(warm_days=WINDOW)
        self.assertEqual(steps["carry"]["outcome"], "skipped")
        self.assertEqual(steps["outcome"]["outputs"].get("good"), "true", self.describe(steps))

    def test_warm_run_missing_a_day_goes_red(self):
        steps, self.work = replay(warm_days=[d for d in WINDOW if d != SEP9])
        self.assertEqual(steps["outcome"]["outputs"].get("good"), "false", self.describe(steps))


if __name__ == "__main__":
    unittest.main()
