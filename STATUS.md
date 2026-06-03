# Status — what works, what doesn't (v0)

This Action is a **scaffold**. The `action.yml` defines the contract we
intend to ship; the bash implementation is real-looking but several
steps depend on upstream primitives that aren't yet in place. This file
enumerates them so the team knows what to ship next.

## Recent fixes (2026-05-24 → 2026-05-25 chain)

The dogfood cloud-CI was silent for ~2 days — every job failed but the
failure-debug comment that should have surfaced the error came back
useless ("ssh debug@.boxes.containarium.dev" with an empty host).
Diagnosing one failure mode let the next surface. Five layers, five
fixes:

1. **#9 — `gh` → curl fallback.** Failure-handling step used `gh pr
   comment` to post debug info; self-hosted runners don't ship `gh`,
   so the comment never landed at all, hiding all subsequent layers.
   Fixed by falling back to a curl call against GitHub's REST API
   (jq is already a hard dep). Comments now post regardless of `gh`.
2. **#10 — `yq` → python3+PyYAML.** Parse-containarium.yml step used
   `yq`, not present on self-hosted runners. Replaced with
   `python3 + import yaml` — present on every Linux runner GHA
   supports; partial-config path emits a clear "apt-get install
   python3-yaml" error.
3. **#11 — `--ssh-key` per-run keypair.** `containarium create`
   requires `--ssh-key`; the action didn't pass one and create-box
   exit-1'd. New step (3a) mints a fresh ed25519 keypair under
   `$RUNNER_TEMP`, passes the pubkey at create, uses the privkey
   for the subsequent ssh / rsync / scp calls. Drops
   `ssh-config sync` (meant for persistent users, not one-shot CI).
4. **#12 — 32-char box-name cap.** Daemon's jump-server username
   validator caps at 32 chars; the action's
   `ci-<repo>-<run-id>-<attempt>` template exceeded it for any
   reasonably-named repo. Truncated to `ci-<run-id>-<attempt>`
   (`GITHUB_RUN_ID` is globally unique).
5. **Issue #13 — `expose-port` flag mismatches (deferred).**
   `expose-port` step passes `--port` (CLI wants `--container-port`),
   missing required `--domain`, references nonexistent `--output url`.
   Doesn't fire on the test-only cloud CI (no `serve:` block), so
   filed an issue rather than speculating on the PR-preview hostname
   contract.

## Works today

- Action surface: inputs, outputs, branding, composite-action shape
- `.github/containarium.yml` parsing with `yq` (preinstalled on `ubuntu-latest`)
- Box naming convention (`ci-<repo>-<run-id>-<attempt>`)
- SSH-based source push + setup/test execution (assumes a working
  `containarium ssh-config sync` against the configured `api-url`)
- Drops `/workspace/.containarium/ci-context.json` into the box on
  create + failure; agent-box upstream change exposes it as an MCP
  resource (separate PR)

## In-flight upstream — `FootprintAI/containarium`

### 1. CLI-only install path ✅ in [PR #295](https://github.com/FootprintAI/Containarium/pull/295)
New `hacks/install-cli.sh` downloads just the CLI binary from the
release. Release workflow already publishes `containarium-{linux,darwin}-{amd64,arm64}`
assets at the standard URL, so the script is a ~50-line wrapper.

### 2. Remote-targeting flags ✅ already existed (correction)
Initial scoping was wrong on this one — the CLI already has `--server`
/ `--token` / `--http` / `--insecure` / `--certs-dir` as PersistentFlags
on root. [PR #295](https://github.com/FootprintAI/Containarium/pull/295)
just adds env-var defaults (`CONTAINARIUM_SERVER`, `CONTAINARIUM_TOKEN`,
etc.) so CI workflows don't repeat flags on every invocation.

The action.yml should use `CONTAINARIUM_SERVER` (matching the existing
flag), not `CONTAINARIUM_API_URL` — corrected in the same commit as
this STATUS update.

### 3. Box TTL / auto-delete — wired (v1.1.1)
The failure path keeps the box alive for debugging, then stamps a 1h
auto-delete so it self-reaps instead of leaking. The action POSTs
`{"durationSeconds": 3600}` to the OSS contract's
`POST /v1/containers/<cld-id>/ttl` (SetContainerTTL); the daemon's
`ttlsweeper` force-deletes once the wall clock passes the expiry. The
call is best-effort — a server predating the handler returns 501 and
the step warns rather than failing the (already-red) build.

Residual gap: this only covers the *kept-alive failure* box. A
**cancelled** job (neither success nor failure) still skips both the
success teardown and this failure-path TTL, so it can leak. Closing
that needs an `if: always()` reaper or a TTL stamped at create time as
a blanket safety net.

## Blocked on Cloud API

### 4. Token issuance flow
Cloud needs an externally-facing way to mint API tokens scoped to a
repo/org for CI usage. Today there's no documented flow for
"give me a token I can paste into GitHub Secrets."

Suggested shape: at `cloud.containarium.dev`, a "GitHub integration"
page that issues a long-lived token tied to a specific repo, with
revocation. Same flow needed for the future PR-preview GitHub App.

### 5. Pages.dev-style preview subdomain routing
For the `serve:` block to yield a real public URL like
`pr-123-myrepo.preview.containarium.dev`, the sentinel needs wildcard
DNS + cert provisioning. May already exist for the OSS demo
(`helloworld.demo.containarium.dev`) — needs confirmation that the
same flow works for ephemeral per-PR subdomains.

## Nice-to-have follow-ups (don't block v0)

### 6. Sticky PR comments
The failure debug comment currently posts a new comment on every retry.
Should find any existing `containarium-bot` comment on the PR and edit
it instead. ~30 lines of bash with `gh api`.

### 7. Cache-key implementation
`cache-key` input is accepted but ignored in v0. Implementing it
requires per-key persistent volumes on the Containarium side (mounted
into the box at create time). Probably belongs in v0.2.

### 8. Composite → JS Action upgrade
v0 is bash. If/when complexity grows past ~200 lines, port to a Node
20 / TypeScript Action for proper error handling, structured comment
posting, and unit-testability.

## Sequence to first working end-to-end run

1. Ship items 1 + 2 (CLI-only install + remote-targeting flags) — small Go PR.
2. Ship item 4 (token issuance flow) — Cloud feature.
3. Dogfood on one workflow in `Containarium-cloud` (`webui` is smallest).
4. Iterate.

Until items 1, 2, and 4 land, this Action will fail at step 3
("Create Containarium box") with an auth error — by design.
