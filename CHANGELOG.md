# Changelog

## Unreleased

- Schedule coverage: `int_scheduled_subway_trips` now builds the schedule for every service date loaded in LAMP staging plus every date in the 90-day reporting window (so a day MBTA has not published still has its schedule), not only the window. When a date rolled out of the window, its trips lost their schedule match and the duplicate-attribution check failed (daily refresh failing since Oct 29). Covered by a unit test and `scripts/tests/schedule_window_regression.sh`. Warehouse cache key bumped to `mbta-duckdb-v4`, so the first run after this rebuilds from scratch.
- DST: run spans in `int_train_runs` are computed from epochs, so the Oct 31 fall-back no longer produces negative run times.
- Green Line: the latest-day sentence is no longer blank when no runs were compared.
- Daily refresh: any run that republishes the last good site now ends as failed (`scripts/fallback_alarm.sh`); the grace-period exit 0 is gone.
- Daily refresh: new `site_freshness` job checks after every deploy attempt that the live `board_data.json` is under 26 hours old.
- Cold start: on a warehouse cache miss the daily refresh restores the previous warehouse and copies over days MBTA has since republished empty (`scripts/carry_forward_lamp_days.py`). Without it the first v4 build would drop 2026-09-09, which the live site shows.
