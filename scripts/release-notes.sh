#!/usr/bin/env bash
# Prints the CHANGELOG.md section "## [<version>]" (without its heading); empty if there is none.
set -euo pipefail

version=${1:?usage: release-notes.sh <version>}
[[ -f CHANGELOG.md ]] || exit 0
awk -v v="$version" '
  /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  found { print }
' CHANGELOG.md | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
