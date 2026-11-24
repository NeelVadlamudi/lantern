# Security

Lantern is a static board built from public MBTA and MassDOT data. Nothing here needs an
account, a key or a paid service, and the repository holds no secrets: the workflows use only
the built-in `GITHUB_TOKEN`, with no permission by default and each job asking for just what
it needs.

The supply chain is kept plain on purpose:

- Every GitHub Action is pinned to a full commit SHA, and Dependabot opens the pull requests
  that move a pin.
- A leak scan (scripts/leak_scan.sh) runs on the tracked files and again on the built site,
  so paths, addresses or keys cannot reach the published page unnoticed.
- OpenSSF Scorecard runs weekly and publishes to the Security tab.

Found a problem — a secret that should not be here, a workflow doing more than it should, or
data on the live board that is not public MBTA data? Open an issue on this repository, or use
GitHub's private vulnerability reporting on the Security tab if it is enabled. Please do not
post a live secret in a public issue; say what kind of thing it is and where, and it will be
rotated or removed first and discussed after.
