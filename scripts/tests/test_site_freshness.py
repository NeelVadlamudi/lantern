import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from site_freshness import check  # noqa: E402

NOW = datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc)


def board(ts):
    return {"build": {"generated_at_utc": ts}}


def test_fresh_build_passes():
    assert check(board("2026-11-01T12:00:00.000000Z"), NOW)[0]


def test_oct29_build_fails_and_names_date():
    ok, msg = check(board("2026-10-29T17:31:48.786208Z"), NOW)
    assert not ok and "2026-10-29" in msg


def test_just_over_limit_fails():
    ts = (NOW - timedelta(hours=26, minutes=1)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    assert not check(board(ts), NOW)[0]


def test_missing_or_bad_timestamp_fails():
    assert not check({}, NOW)[0]
    assert not check(board("yesterday"), NOW)[0]
