#!/usr/bin/env bash
# Download the MBTA Open Data CSVs to local files before dbt reads them. The ArcGIS download
# endpoints can answer 202 while an export is being generated, or change the file mid-read;
# curl retries until a complete 200 response arrives. Prints the dbt --vars mapping: each
# source that downloaded points at its local copy; a source that did not keeps its cached
# staging table (keep_reference_tables) when the warehouse already has one.
set -uo pipefail
dir="${1:-warehouse/mirror}"
mkdir -p "$dir"
vars="refresh_reference: true"
keep=""
while read -r var model url; do
  out="$dir/$var.csv"
  ok=false
  for attempt in 1 2 3 4 5 6; do
    code=$(curl -sS -L --max-time 300 -o "$out.part" -w '%{http_code}' "$url" || echo 000)
    if [ "$code" = "200" ] && [ -s "$out.part" ]; then mv "$out.part" "$out"; ok=true; break; fi
    echo "$var: attempt $attempt returned HTTP $code; retrying" >&2
    sleep $((attempt * 20))
  done
  rm -f "$out.part"
  if $ok; then vars="$vars, $var: '$out'"; else
    echo "$var: download failed; keeping the cached $model" >&2
    keep="${keep:+$keep, }$model"
  fi
done <<'LIST'
gated_entries_url stg_mbta__gated_entries https://mbta-massdot.opendata.arcgis.com/api/download/v1/items/001c177f07594e7c99f193dde32284c9/csv?layers=0
monthly_ridership_url stg_mbta__monthly_ridership https://mbta-massdot.opendata.arcgis.com/api/download/v1/items/2048258a18354256a650d41f8fe4532c/csv?layers=0
cr_reliability_url stg_mbta__cr_reliability https://www.arcgis.com/sharing/rest/content/items/ec18161c237d419698abc767f1be6a50/data
cr_boardings_url stg_mbta__cr_boardings https://www.arcgis.com/sharing/rest/content/items/59b5c61e8e9f42f9a3745f7ad63d07d6/data
passenger_survey_url stg_mbta__passenger_survey https://mbta-massdot.opendata.arcgis.com/api/download/v1/items/2dac9c48bd3440c2bcf2a220614c667b/csv?layers=0
LIST
echo "{$vars, keep_reference_tables: [$keep]}"
