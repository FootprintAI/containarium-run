#!/usr/bin/env bash
#
# teardown-runners.sh — stop, deregister, and remove the co-located
# runners created by setup-runners.sh.
#
# Usage (run as the same non-root user that set them up):
#   GH_TOKEN="$(gh api -X POST repos/FootprintAI/Containarium-cloud/actions/runners/remove-token -q .token)" \
#   ./hack/teardown-runners.sh
#
# GH_TOKEN here is a *remove* token (not a registration token). Without
# it the runner is still stopped + removed locally, but stays listed on
# GitHub as "offline" until it ages out.

set -euo pipefail

BASE_DIR="${BASE_DIR:-$HOME/actions-runners}"
PREFIX="${PREFIX:-cnt-runner}"
GH_TOKEN="${GH_TOKEN:-}"

shopt -s nullglob
removed=0
for dir in "$BASE_DIR"/${PREFIX}-*; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  (
    cd "$dir"
    sudo ./svc.sh stop      2>/dev/null || true
    sudo ./svc.sh uninstall 2>/dev/null || true
    if [ -n "$GH_TOKEN" ]; then
      ./config.sh remove --token "$GH_TOKEN" 2>/dev/null || true
    fi
  )
  rm -rf "$dir"
  echo "removed: $name"
  removed=$((removed + 1))
done
echo "done: removed $removed runner(s) from $BASE_DIR"
