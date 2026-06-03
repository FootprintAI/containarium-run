#!/usr/bin/env bash
#
# setup-runners.sh — provision N co-located GitHub Actions self-hosted
# runners for containarium-run-based CI, to get CONCURRENT jobs.
#
# Why this works cheaply: a containarium-run job is a LIGHTWEIGHT
# ORCHESTRATOR — it only creates a box, ssh's in, and runs your
# setup/test there; the heavy compute lives in the box on the regional
# daemon, NOT on the runner. So many runners can share one host. Job
# concurrency = number of runners, bounded by the BACKEND POOL's
# capacity (see docs/RUNNERS.md), not by this host's CPU.
#
# One runner serializes every job in a workflow. N runners let GitHub
# dispatch up to N jobs in parallel — each into its own box.
#
# Usage (run as a NON-root user that can sudo):
#   GH_URL=https://github.com/FootprintAI/Containarium-cloud \
#   GH_TOKEN="$(gh api -X POST repos/FootprintAI/Containarium-cloud/actions/runners/registration-token -q .token)" \
#   COUNT=8 \
#   ./hack/setup-runners.sh
#
# Re-runnable: existing runners (by name) are skipped. Bump COUNT and
# re-run to add more. See teardown-runners.sh to remove them.
#
# Org-wide instead of one repo: point GH_URL at the org
# (https://github.com/FootprintAI) and mint the token from
# orgs/<org>/actions/runners/registration-token. Then every repo's
# containarium-run jobs share the fleet.

set -euo pipefail

GH_URL="${GH_URL:?set GH_URL to the repo or org URL}"
GH_TOKEN="${GH_TOKEN:?set GH_TOKEN to a runner *registration* token (single token registers all N within its ~1h window)}"
COUNT="${COUNT:-8}"
# self-hosted/Linux/X64 are auto-added by the runner; the workflow's
# `runs-on: [self-hosted, Linux, X64]` matches on those. The extra
# `containarium` label lets you target this fleet explicitly later.
LABELS="${LABELS:-containarium}"
BASE_DIR="${BASE_DIR:-$HOME/actions-runners}"
PREFIX="${PREFIX:-cnt-runner}"

if [ "$(id -u)" = "0" ]; then
  echo "Run as a non-root user (the GitHub runner refuses to run as root); sudo is used only for the service install." >&2
  exit 2
fi

# Orchestrator prerequisites. NOT rsync — containarium-run uses tar.
# The containarium CLI is installed by the action itself per run.
for c in curl tar git python3 jq; do
  command -v "$c" >/dev/null || { echo "missing prerequisite: $c"; exit 1; }
done

# Resolve the latest runner release unless pinned, so we never 404 on a
# stale hardcoded version.
RUNNER_VERSION="${RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')}"
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
DL_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"
if [ ! -f "$TARBALL" ]; then
  echo "downloading runner v${RUNNER_VERSION} ..."
  curl -fsSL -o "$TARBALL" "$DL_URL"
fi

host="$(hostname -s)"
made=0
for i in $(seq 1 "$COUNT"); do
  name="${PREFIX}-${host}-${i}"
  dir="$BASE_DIR/$name"
  if [ -d "$dir" ]; then
    echo "skip existing: $name"
    continue
  fi
  mkdir -p "$dir"
  tar -xzf "$TARBALL" -C "$dir"
  (
    cd "$dir"
    ./config.sh --unattended --replace \
      --url "$GH_URL" --token "$GH_TOKEN" \
      --name "$name" --labels "$LABELS" \
      --work "_work"
    # Install as a systemd service so the runner survives reboots and
    # SSH-session-end (the same linger footgun the podman stack hit).
    sudo ./svc.sh install "$USER"
    sudo ./svc.sh start
  )
  echo "registered + started: $name"
  made=$((made + 1))
done

echo
echo "done: $made new runner(s); fleet labeled [self-hosted,Linux,X64,$LABELS] under $BASE_DIR"
echo "verify: gh api repos/<owner>/<repo>/actions/runners -q '.runners[] | \"\\(.name) \\(.status) busy=\\(.busy)\"'"
echo
echo "Concurrency is now min(#runners, backend-pool capacity). If jobs"
echo "still queue, the ceiling is the pool — add backends and/or shrink"
echo "the box size in your containarium.yml. See docs/RUNNERS.md."
