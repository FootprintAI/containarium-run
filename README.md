# containarium-run

> **Status: v0 scaffold.** The action surface is the intended contract.
> Several pieces require upstream changes in `FootprintAI/containarium`
> and the Cloud API to fully work end-to-end — see [STATUS.md](STATUS.md).

A GitHub Action that runs your CI tests inside a [Containarium](https://containarium.dev)
box. Unlike GitHub-hosted runners, the box is a **real Linux container**
you can SSH into, hand off to an agent, and keep alive on failure for
post-mortem debugging.

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
      - uses: FootprintAI/containarium-run@v0
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

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `server` | No | `https://api.containarium.dev` | Containarium server address (matches CLI's `--server` flag / `CONTAINARIUM_SERVER` env var). Point at your self-hosted instance if not using Cloud. |
| `token` | **Yes** | — | API token. Use a GitHub Actions secret. |
| `config` | No | `.github/containarium.yml` | Path to the containarium config file in your repo. |
| `cache-key` | No | — | *(v0: not yet implemented)* Cache key to reuse a warm box across runs (e.g. `${{ hashFiles('go.sum') }}`). |
| `keep-on-failure` | No | `true` | On test failure, keep box alive 1h and post a debug comment on the PR. |

## Outputs

| Name | When | Description |
|---|---|---|
| `box-id` | always | The Containarium box ID created for this run. |
| `preview-url` | when `serve:` block defined | Public URL of the served app. |
| `debug-url` | on failure with `keep-on-failure: true` | Agent-box MCP URL for interactive debugging. |

## `containarium.yml` schema (v0)

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

Three fields (plus the optional `serve:`). Resist adding a fourth in v1
unless the use case is universal.

## Self-hosted

Same Action, different `api-url`:
```yaml
- uses: FootprintAI/containarium-run@v0
  with:
    server: https://containarium.your-company.internal:8080
    token:  ${{ secrets.CONTAINARIUM_TOKEN }}
```

The Cloud token issuance flow lives at
[cloud.containarium.dev](https://cloud.containarium.dev); for self-hosted,
issue your own tokens via the platform admin CLI.

## Project home

- Marketing site: [containarium.dev](https://containarium.dev)
- OSS repo (CLI, daemon, agent-box): [FootprintAI/containarium](https://github.com/FootprintAI/containarium)
- Cloud control plane: [cloud.containarium.dev](https://cloud.containarium.dev)
- Issues / feedback: [GitHub Issues](https://github.com/FootprintAI/containarium-run/issues)

## License

[Apache 2.0](LICENSE).
