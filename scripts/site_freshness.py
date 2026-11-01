"""Fail when the live Lantern site serves data older than the allowed age.

Reads build.generated_at_utc from the deployed board_data.json. Exit 0 when fresh,
1 when stale or unreadable, so a fallback to an old build can never look like a success.
"""
import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

MAX_AGE = timedelta(hours=26)  # one daily run plus slack for a late schedule


def check(board: dict, now: datetime, max_age: timedelta = MAX_AGE) -> tuple[bool, str]:
    try:
        raw = board["build"]["generated_at_utc"]
        built = datetime.strptime(raw, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
    except (KeyError, TypeError, ValueError):
        return False, "STALE: the live site has no readable build.generated_at_utc"
    age = now - built
    hours = age.total_seconds() / 3600
    if age > max_age:
        return False, f"STALE: the live site is serving data built {raw[:10]} ({hours:.0f}h old)"
    return True, f"FRESH: the live site data was built {raw} ({hours:.1f}h old)"


def main(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            board = json.load(r)
    except Exception as e:  # network or JSON failure counts as stale
        print(f"::error::STALE: could not read {url}: {e}")
        return 1
    ok, msg = check(board, datetime.now(timezone.utc))
    print(msg if ok else f"::error::{msg}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
