# Scaling self-hosted runners for concurrent box-CI

By default, one self-hosted runner runs your `containarium-run` jobs **one
at a time** — every job in a workflow serializes onto it. This doc is how to
run them **concurrently**, each job in its own box.

## The key idea: the runner is a lightweight orchestrator

A `containarium-run` job does almost no work *on the runner*:

```
runner:  create box (API) → wait RUNNING → ssh → tar source → ssh setup/test → teardown
box:     <-------------------- the actual build/test compute lives here -------------------->
```

So a runner is cheap to multiply — you can run **many runner processes on one
host**, because the heavy lifting happens in the box on the regional daemon,
not on the runner. **Job concurrency = number of runners**, capped by backend
capacity (below).

## Two layers of concurrency

### Layer 1 — dispatch: more runners (the easy win)

GitHub dispatches queued jobs to any free runner whose labels match
`runs-on`. With N runners labeled `self-hosted, Linux, X64`, up to N of a
workflow's jobs run in parallel.

```bash
# On the runner host, as a non-root user that can sudo:
GH_URL=https://github.com/FootprintAI/Containarium-cloud \
GH_TOKEN="$(gh api -X POST \
  repos/FootprintAI/Containarium-cloud/actions/runners/registration-token \
  -q .token)" \
COUNT=8 \
./hack/setup-runners.sh
```

This downloads the runner once, then registers + starts `COUNT` systemd
services (`cnt-runner-<host>-1..N`). Re-run with a larger `COUNT` to add more;
`./hack/teardown-runners.sh` removes them.

Org-wide: point `GH_URL` at the org and mint the token from
`orgs/<org>/actions/runners/registration-token` — then every repo's
`containarium-run` jobs share the fleet.

Verify:

```bash
gh api repos/FootprintAI/Containarium-cloud/actions/runners \
  -q '.runners[] | "\(.name) \(.status) busy=\(.busy)"'
```

### Layer 2 — execution: backend pool capacity (the real ceiling)

Each box consumes real CPU/RAM on its backend host. If the CI box default is
**4cpu/4GB** and a host has 4 vCPU, 8 concurrent boxes request 32 vCPU on 4
cores → heavy overcommit, CPU-starved tests. So adding runners past the pool's
capacity just moves the queue from GitHub to the daemon's driver-queue (which
absorbs bursts gracefully, but can't create capacity).

Two levers raise the real ceiling:

- **Add backends to the pool.** More hosts tagged into `cloud-tenants` →
  boxes spread across them. The driver registry places per region; the
  driver-queue drains bursts.
- **Right-size CI boxes.** CI rarely needs 4 cores. A smaller box fits more
  concurrent boxes per host, since packing is roughly
  `floor(host vCPU / box vCPU)` — e.g. on a 16-vCPU host, 2-vCPU boxes pack 8
  vs four 4-vCPU boxes. Set the size two ways (first non-empty wins):
  - **`resources:` in `containarium.yml`** — per-repo:
    ```yaml
    resources:
      cpu: "2"
      memory: "2GB"
      disk: "30GB"
    ```
  - **`box-cpu` / `box-memory` / `box-disk` action inputs** — per-workflow;
    default `4` / `4GB` / `50GB` when neither is set.

  Size to the build's real CPU/RAM peak plus headroom — undersizing trades
  queue time for slower builds, and under-provisioned **memory OOM-kills**
  the build rather than just slowing it. The chosen size is echoed in the run
  logs (`box size: cpu=… memory=… disk=…`).

**Rule of thumb:** set `COUNT` ≈ `floor(total pool vCPU / box vCPU)`, leaving
headroom for the daemon itself. Lower `box vCPU` raises *both* the per-host
packing density and the runner `COUNT` you can usefully run.

## Persistent vs ephemeral runners

`setup-runners.sh` registers **persistent** runners (reused across jobs).
That's fine here: the runner holds no build state — every job's checkout lands
in a fresh `_work` and the compute is in a throwaway box. If you want
one-job-then-deregister isolation (or autoscaling), pass `--ephemeral` in
`config.sh` and add a supervisor that re-registers on exit (e.g.
actions-runner-controller). For a fixed self-hosted fleet, persistent is
simpler and sufficient.

## Prerequisites on the runner host

Universally-present tools the orchestrator needs: `curl`, `tar`, `git`,
`python3`, `jq`. Notably **not** `rsync` (the action uses tar-over-ssh) and
**not** any test toolchain (Go/Node/etc. install inside the box). The
`containarium` CLI is installed by the action per run.

## Gotchas

- **Linger.** The runner services are systemd units; ensure the host doesn't
  kill them on logout (`loginctl enable-linger <user>` if running rootless
  user services) — the same footgun the podman control-plane stack hit.
- **`concurrency: cancel-in-progress`** in a workflow is per-ref (cancels
  superseded runs of the same branch), *not* a within-run parallelism cap —
  it doesn't limit how many jobs run at once.
- **Registration token TTL** ~1h; it registers all N runners within that
  window, so mint it right before running the script.
