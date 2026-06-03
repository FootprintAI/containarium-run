# Box sizing & per-host concurrency

Each CI job runs in its own Containarium box. How big that box is decides two
things: whether your build has the CPU/RAM/disk it needs, and how many jobs
can pack onto one backend host at once. This doc explains the knobs and the
trade-off.

## The knobs

A box's size comes from three values, resolved in this order (first non-empty
wins):

1. **`resources:` in `containarium.yml`** — per-repo, lives next to your build
   config:
   ```yaml
   resources:
     cpu: "2"
     memory: "2GB"
     disk: "30GB"
   ```
2. **Action inputs** — per-workflow, set on the `uses:` step:
   ```yaml
   - uses: FootprintAI/containarium-run@v1
     with:
       box-cpu: "2"
       box-memory: "2GB"
       box-disk: "30GB"
   ```
3. **Defaults** — `4` cores / `4GB` / `50GB` when neither is set (the
   pre-sizing behaviour, so existing workflows are unchanged).

Use the `containarium.yml` block when the size is a property of *the repo*
(this project needs 8GB to compile); use the action inputs when it's a
property of *the workflow* (a default for several repos, or an override for
one job).

## Why smaller boxes can mean faster CI

Containarium packs multiple boxes onto each backend host. Roughly:

```
boxes per host ≈ floor(host vCPU / box vCPU)
```

So on a 16-vCPU host:

| box-cpu | boxes that fit | effect |
|--------:|---------------:|--------|
| 4 (default) | 4 | fewer, roomier boxes |
| 2 | 8 | 2× the parallel jobs per host |
| 1 | 16 | maximum fan-out |

If your matrix fans out to 20 jobs, 2-vCPU boxes clear them in far fewer
waves than 4-vCPU boxes — provided each job actually fits in 2 vCPU. Memory
and disk pack the same way against the host's totals.

## The trade-off

Smaller boxes increase throughput **only up to the point where the build
still fits**. Undersize it and you trade queue time for slower (or failing)
builds:

- **CPU**: a compile that saturates 4 cores will roughly double in wall-clock
  on 2 — you may pack more jobs but each takes longer. Net throughput can still
  win; per-job latency loses.
- **Memory**: under-provisioning is a hard failure — the OOM killer takes your
  build, not just slows it. Size memory to the build's actual peak.
- **Disk**: must hold the image + checkout + build artifacts + caches. Cheapest
  to be generous on; disk rarely limits packing as much as CPU/RAM.

Rule of thumb: **measure your build's real CPU/RAM peak, set the box to that
plus headroom, and let the host packing take care of concurrency.** Don't
shrink boxes below what the build needs just to chase parallelism.

## Notes

- Sizes are passed straight through to the box at create time; there's no
  autoscaling within a run — a box is one fixed size for its lifetime.
- On Containarium Cloud, the backend host pool and its vCPU counts are managed
  for you; on self-hosted, packing is bounded by whatever backends you've
  registered.
- The box size shows up in the run logs (`box size: cpu=… memory=… disk=…`) so
  you can confirm which source won the resolution above.
