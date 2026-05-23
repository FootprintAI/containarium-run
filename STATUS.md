# Status — what works, what doesn't (v0)

This Action is a **scaffold**. The `action.yml` defines the contract we
intend to ship; the bash implementation is real-looking but several
steps depend on upstream primitives that aren't yet in place. This file
enumerates them so the team knows what to ship next.

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

### 3. Box TTL / auto-delete — still missing
The failure path is supposed to keep the box alive for 1h then auto-
delete. The CLI has no `containarium ttl set <box> 1h` verb today;
the box would leak indefinitely. Either:
- add a CLI verb, or
- add a TTL field to `CreateContainerRequest` in the cloud proto, set
  at create time

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
