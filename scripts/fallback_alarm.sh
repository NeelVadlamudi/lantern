#!/usr/bin/env bash
# Ends the daily refresh as failed whenever this run's build was not good and the last good
# site was republished instead. Prints the date of the build being served so the failure says
# what viewers are seeing. A fallback must never look green.
#   usage: fallback_alarm.sh <good> <previous_health.json> <restored: true|false>
#   <good>      "true" when this run's build and tests passed (steps.outcome.outputs.good)
#   <restored>  "true" when the last good site was restored from cache
# Exit 0 only when good is "true"; otherwise writes a GitHub ::error:: annotation and exits 1.
set -uo pipefail
good=${1:-false}
health=${2:-previous_health.json}
restored=${3:-false}

if [ "$good" = "true" ]; then
  echo "Build passed: this run's site is published."
  exit 0
fi

served=$(jq -r '[.runs[]? | select(.status == "pass") | .run_date] | max // ""' "$health" 2>/dev/null || true)
if [ "$restored" = "true" ]; then
  msg="Build failed; FALLBACK: the site is serving the last good build from ${served:-an unknown date} (no newer data published)."
else
  msg="Build failed and no last good site was found; nothing new was published (last passing build: ${served:-never})."
fi
echo "::error title=Daily refresh fell back::$msg"
echo "$msg"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "### Daily refresh fell back to the last good build" >> "$GITHUB_STEP_SUMMARY"
  echo "$msg" >> "$GITHUB_STEP_SUMMARY"
fi
exit 1
