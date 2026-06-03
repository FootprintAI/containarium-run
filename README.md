# containarium-run

[![Release](https://img.shields.io/github/v/release/FootprintAI/containarium-run?label=release&color=indigo)](https://github.com/FootprintAI/containarium-run/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Public — Tier 0 evaluators welcome](https://img.shields.io/badge/public-tier%200%20evaluators%20welcome-emerald)](https://containarium.dev/#ci)

A GitHub Action that runs your CI tests inside a [Containarium](https://containarium.dev)
box. Unlike GitHub-hosted runners, the box is a **real Linux container**
you can SSH into, hand off to an agent, and keep alive on failure for
post-mortem debugging.

Pin to a release tag (`@v1`) rather than `@main`:

```yaml
- uses: FootprintAI/containarium-run@v1
  with:
    server: https://cloud.containarium.dev
    token:  ${{ secrets.CONTAINARIUM_TOKEN }}
```

Don't have a token yet? See [containarium.dev/#ci](https://containarium.dev/#ci) for the 5-minute Tier 0 path (signup + mint a token at `cloud.containarium.dev/settings/api-tokens` + paste into a GitHub Secret).

## Quick start

In your repo:

**`.github/workflows/test.yml`**
```yaml
name: CI
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: FootprintAI/containarium-run@v1
        with:
          server: ${{ secrets.CONTAINARIUM_SERVER }}
          token:  ${{ secrets.CONTAINARIUM_TOKEN }}
```

**`.github/containarium.yml`**
```yaml
image: ubuntu-24.04
setup:
  - apt-get install -y build-essential
  - go mod download
test:
  - go test ./...
```

## What you get

- **Real Linux per job**: `systemd`, full networking, persistent filesystem during the run.
- **Debug on failure**: when a test fails, the box stays alive for an hour and a comment is posted on your PR with an SSH command and an [agent-box](https://github.com/FootprintAI/containarium/tree/main/cmd/agent-box) MCP URL. Connect from Claude Code, Cursor, or any MCP client and debug in place.
- **Preview environments** (optional): add a `serve:` block to `containarium.yml` and the action exposes the port on a public HTTPS subdomain for the duration of the run.

> How the box lifecycle, SSH identity model, and source transfer actually work
> (and *why*) — see [docs/FLOW.md](docs/FLOW.md).

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `server` | No | `https://cloud.containarium.dev` | Containarium server address (matches CLI's `--server` flag / `CONTAINARIUM_SERVER` env var). Point at your self-hosted instance if not using Cloud. |
| `token` | **Yes** | — | API token. Use a GitHub Actions secret. |
| `config` | No | `.github/containarium.yml` | Path to the containarium config file in your repo. |
| `box-cpu` | No | `4` | CPU cores for the box. Smaller boxes pack more parallel jobs per backend host (see [docs/RUNNERS.md](docs/RUNNERS.md)). A `resources.cpu` in `containarium.yml` overrides this per-role. |
| `box-memory` | No | `4GB` | Memory for the box. Overridden by `resources.memory` in `containarium.yml`. |
| `box-disk` | No | `50GB` | Disk for the box. Overridden by `resources.disk` in `containarium.yml`. |
| `cache-key` | No | — | *(planned; not in v1)* Cache key to reuse a warm box across runs (e.g. `${{ hashFiles('go.sum') }}`). |
| `keep-on-failure` | No | `true` | On test failure, keep box alive 1h and post a debug comment on the PR. |
| `org-id` | No | — | Cloud org UUID. When set, debug-box endpoint info (SSH host/port/user, MCP URL, keep-alive deadline) is reported back to the cloud's CI dashboard on test failure so the `/ci/runs/<id>` panel renders real connection info. Skipped silently when empty — preserves backwards-compat for users who haven't run the onboarding wizard. |
| `ssh-host` | No | — | *(stopgap)* SSH host for the box. Normally unset — the create response's `sshHost` field supplies it (the cloud is the only party that knows it; the region code isn't the DNS label). Set this only if your cloud hasn't yet been configured to return `sshHost`. |
| `preview-domain` | No | — | Public hostname to route to the container when `containarium.yml` has a `serve:` block (e.g. `pr-${{ github.event.pull_request.number }}.previews.example.com`). Required by the CLI; when empty, the expose step is skipped with a log line (the serve command still runs inside the box, but no public route is wired). See [#13](https://github.com/FootprintAI/containarium-run/issues/13) for the design discussion. |

## Outputs

| Name | When | Description |
|---|---|---|
| `box-id` | always | The Containarium box ID created for this run. |
| `preview-url` | when `serve:` block defined | Public URL of the served app. |
| `debug-url` | on failure with `keep-on-failure: true` | Agent-box MCP URL for interactive debugging. |

## `containarium.yml` schema

```yaml
image: ubuntu-24.04          # required — base image
setup:                       # optional — runs once, build deps + caches
  - <shell command>
test:                        # required — your actual test command
  - <shell command>
serve:                       # optional — for PR preview environments
  command: <shell command>
  port: <int>
```

Three fields (plus the optional `serve:`). Resist adding a fourth in
v1.x unless the use case is universal.

## Self-hosted

Same Action, different `api-url`:
```yaml
- uses: FootprintAI/containarium-run@v1
  with:
    server: https://containarium.your-company.internal:8080
    token:  ${{ secrets.CONTAINARIUM_TOKEN }}
```

The Cloud token issuance flow lives at
[cloud.containarium.dev](https://cloud.containarium.dev); for self-hosted,
issue your own tokens via the platform admin CLI.

## Agent context (`.containarium/ci-context.json`)

When the box is created, the action drops a small JSON file into
`/workspace/.containarium/ci-context.json` describing the CI run that
spawned it — repo, PR number/title/URL, commit SHA, branch, actor,
GitHub run URL, workspace path. On failure, the same file is refreshed
with the failing test name and the last ~50 lines of test output.

The companion [agent-box](https://github.com/FootprintAI/containarium/tree/main/cmd/agent-box)
exposes this file as an MCP resource (`containarium://ci-context`) so an agent
connecting to a failing box has the full picture on its first turn —
no "what am I looking at?" round-trip required. A second resource
(`containarium://ci-prompt`) provides an opinionated playbook for
debugging failing CI runs inside Containarium boxes — read alongside
the context.

## Project home

- Marketing site: [containarium.dev](https://containarium.dev)
- OSS repo (CLI, daemon, agent-box): [FootprintAI/containarium](https://github.com/FootprintAI/containarium)
- Cloud control plane: [cloud.containarium.dev](https://cloud.containarium.dev)
- Issues / feedback: [GitHub Issues](https://github.com/FootprintAI/containarium-run/issues)

## License

[Apache 2.0](LICENSE).
