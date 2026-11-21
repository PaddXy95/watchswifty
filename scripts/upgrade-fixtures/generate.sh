#!/usr/bin/env bash
# Writes the upgrade test fixture of a released version with that version's own code.
#
#   scripts/upgrade-fixtures/generate.sh v0.1.0
#
# Checks the tag out into a temporary worktree, adds scripts/upgrade-fixtures/<tag>.swift as a test there, runs it
# with UPGRADE_FIXTURE_PATH and stores the database as Tests/AppTests/Fixtures/upgrade/<tag>.sqlite.
set -euo pipefail

tag="${1:?usage: $0 <tag, e.g. v0.1.0>}"
root="$(git rev-parse --show-toplevel)"
generator="$root/scripts/upgrade-fixtures/$tag.swift"
target="$root/Tests/AppTests/Fixtures/upgrade/$tag.sqlite"
[ -f "$generator" ] || { echo "missing generator $generator" >&2; exit 1; }

work="$(mktemp -d)"
trap 'git -C "$root" worktree remove --force "$work/src" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

git -C "$root" worktree add --detach "$work/src" "$tag" >/dev/null
cp "$generator" "$work/src/Tests/AppTests/UpgradeFixtureGenerator.swift"
(cd "$work/src" && UPGRADE_FIXTURE_PATH="$work/fixture.sqlite" swift test --filter UpgradeFixtureGenerator)
[ -s "$work/fixture.sqlite" ] || { echo "generator wrote no database" >&2; exit 1; }
sqlite3 "$work/fixture.sqlite" "PRAGMA journal_mode=DELETE; VACUUM;" >/dev/null
mkdir -p "$(dirname "$target")"
cp "$work/fixture.sqlite" "$target"
echo "wrote $target"
