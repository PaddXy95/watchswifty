#!/usr/bin/env bash
# Prints the version of the next release.
# - VERSION holds the intended version (bump it for a new minor/major line).
# - If tag v<VERSION> does not exist yet, that is the next version.
# - Otherwise: highest existing patch of the same major.minor line + 1.
set -euo pipefail

base=$(tr -d '[:space:]' < VERSION)
if [[ ! "$base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION must look like 1.2.3, got: '$base'" >&2
  exit 1
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}

if ! git rev-parse -q --verify "refs/tags/v$base" >/dev/null; then
  echo "$base"
  exit 0
fi

highest=$(git tag -l "v$major.$minor.*" | sed -E "s/^v$major\.$minor\.//" | grep -E '^[0-9]+$' | sort -n | tail -1)
echo "$major.$minor.$((highest + 1))"
