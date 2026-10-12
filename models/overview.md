{% docs __overview__ %}
# Lantern

Where the T runs late, from recorded train runs.

dbt Core and DuckDB on public MBTA data: recorded subway train runs and gaps between trains are
compared with the published schedule, with Commuter Rail reliability from the MBTA's own files.
The board is at https://neelvadlamudi.github.io/lantern/ and the source at
https://github.com/NeelVadlamudi/lantern.

## Methods

- **Window.** The last 90 complete service dates from MBTA LAMP (one row per train at a stop),
  with the GTFS schedule in force on each date. Weekdays leave out holidays.
- **Train delay** (headline). Every run between two observed stops is compared with its
  scheduled run time. Late time only = max(run - scheduled, 0); net lets early runs offset late
  ones. Summed per service date and averaged over weekdays.
- **Terminal holds.** On runs that leave a terminal, the recorded time on the platform before
  departure is split out (`terminal_hold_seconds`) and not counted as delay. Runs that end at a
  terminal cannot be split (LAMP has no departure from outside the terminal).
- **Late trips.** A trip is late when its compared stop-to-stop runs add up to more than 5
  minutes over schedule. Runs over 30 minutes are counted and also shown on their own.
- **Long gaps.** A departure whose gap since the previous train on the trunk is more than 1.5
  times the scheduled gap.
- **Rider time lost** is an estimate from gate entries, assuming riders arrive at random. It is
  labelled as an estimate wherever it appears.
- **Typical day.** For the latest day, typical = the median of the same measure on the 28
  earlier service dates of the same day type.
- **Worst window.** Per segment, the 14 consecutive calendar days holding the largest share of
  its train delay, with that share and the window's share of its runs.
- **Commuter Rail and survey** come from the MBTA's own Open Data files as published; they are
  not recomputed from train positions.
- **Checks.** Every board figure is recomputed from the fact tables by the tests under
  `tests/kpi/` on each build; a failing test stops the board files from being published.

Public MBTA data. Live positions from the MBTA V3 API. Not affiliated with the MBTA.
{% enddocs %}
