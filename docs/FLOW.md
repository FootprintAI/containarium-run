# How `containarium-run` works (flow + rationale)

This Action runs your CI **inside a fresh Containarium box** that you can SSH
into when it fails. This doc explains the end-to-end flow and *why* each
non-obvious step is the way it is — so future changes don't reintroduce bugs
we've already paid for.

If you just want to use the Action, see the [README](../README.md). This is
the "how it's wired and why" companion.

## The lifecycle

Every job runs these steps (see [`action.yml`](../action.yml)):

1. **Install the CLI** — used only for `expose-port` (PR previews). Create /
   delete / push talk to the REST API directly (see below).
2. **Parse `containarium.yml`** — image, `setup`, `test`, optional `serve`.
   Parsed with `python3 + PyYAML` (present on every Linux runner) rather than
   `yq` (not preinstalled on self-hosted runners).
3. **Mint a throwaway SSH keypair** — a per-run `ed25519` pair under
   `$RUNNER_TEMP`. The job never carries a long-lived key; GHA discards this
   one at job end.
4. **Create the box** — `POST /v1/containers` over **curl/HTTP1.1** (not the
   CLI; see "Why curl" below). Async: returns immediately with the box in a
   `CREATING`/`PENDING` state.
5. **Wait until ready** — poll the cloud for `RUNNING`, then probe SSH until
   it answers. Create is async, so this avoids racing a half-provisioned box.
6. **Push the working tree** — `containarium sync` into `~/work` (see "Source
   transfer").
7. **Write CI context** — `~/work/.containarium/ci-context.json` (repo, PR,
   commit, run URL) so an agent attached to a failing box has context.
8. **Run `setup`** then **`test`** — over SSH, `cd ~/work && <cmd>`.
9. **Expose** (only if `serve:` is defined) — wire a public preview hostname.
10. **Teardown on success** — `DELETE /v1/containers/<box>`.
11. **On failure** (PR + `keep-on-failure`) — keep the box alive, refresh the
    CI context with the failing test + log tail, post a PR comment with the
    SSH/MCP debug command, and report the debug box to the cloud dashboard.

## The box-SSH identity model

This is the part that's caused the most bugs, so internalize it:

```
ssh <ssh-user>@<ssh-host>
     │              └── the regional sentinel's public hostname
     └── the box's cloud-assigned username, "cld-<short-id>"
```

- **`ssh-user` is `cld-<id>`** — the username the cloud assigns the box, NOT
  the name you sent at create. The jump server (sshpiper) routes by this
  username, and the cloud addresses the box by it on `GET`/`DELETE`. The name
  you pass at create is only the box's human handle.
- **`ssh-host` comes from the create response (`.container.sshHost`)** — the
  client **cannot derive it**: the cloud's region *code* is not the public DNS
  *label*, so only the cloud knows which sentinel fronts the box. The Action
  reads `ssh-user` + `ssh-host` straight from the create response and dials
  `${ssh-user}@${ssh-host}`. (There's an `ssh-host` input as a stopgap for a
  cloud not yet returning `sshHost`.)

**Never reconstruct the SSH host from the box name or region** — that's the bug
that produced `ssh: Could not resolve hostname <box-name>`.

### How auth actually works (keypair → box)

At create we send the **public key's contents** in `sshKeys`. The daemon bakes
that key into the box and registers the box's jump-server account, so sshpiper
authenticates the runner's private key and proxies into the box. The login is a
**non-root** box user, so we work under its home (`~/work`), not at the
filesystem root — `mkdir /workspace` fails with `Permission denied`.

> ⚠️ Send the key **contents**, not the file path. `sshKeys: [<path-to>.pub]`
> stores the literal path as the "key"; the daemon then rejects every create
> with `ssh_keys[0]: not a valid SSH public key: ssh: no key found`. Always
> `cat` the `.pub` file into the request.

## Source transfer: `containarium sync` (use the platform primitive)

We push the working tree with the platform's own source-sync primitive — the
`containarium sync` CLI, which is the same code behind the MCP `sync`/`push`
tools:

```bash
containarium sync "$SSH_USER" . --sentinel "$SSH_HOST" --key "$SSH_KEY"
```

It mirrors the local tree into the box's default **`~/work`** over the same
`sentinel → sshpiper → box` SSH path, then `setup`/`test` run with `cd ~/work`.

Why this and not a hand-rolled transfer (we tried both and hit walls):

- **Not `rsync`.** Base box images ship `tar` but **not** `rsync`, so an rsync
  push dies with `rsync: command not found` → protocol error code 12. (`sync`
  itself uses **tar-over-ssh** under the hood for exactly this reason.)
- **Not a raw `tar` to `/workspace`.** The box logs us in as a **non-root**
  user, so `mkdir /workspace` → `Permission denied`. `sync` targets the
  home-relative `~/work`, which is writable whatever user the box assigns.
- **`sync`, not `push`.** `containarium push` is real `git push` and **refuses
  a detached HEAD** (`detached HEAD; pass --branch`). CI's checkout is a
  *shallow, detached* merge ref, so `sync` — which mirrors the working tree with
  no git/branch ceremony — is the right one here.
- **Don't reinvent it.** The runner can't call MCP tools (no MCP client in the
  GHA bash env), but the CLI behind them is installed and does the right thing —
  workdir, transport, excludes, optional `--delete`. Reach for `containarium
  sync`/`push` before hand-rolling ssh plumbing.

## Why curl (not the CLI) for create/delete

The Go CLI's REST client auto-negotiates HTTP/2, and a long-running create
carried over HTTP/2 through the fronting TLS edge intermittently resets the
response even though the box provisioned. curl defaults to HTTP/1.1 and
sidesteps it. Create is also made **idempotent**: on a non-2xx we check whether
the box exists before retrying, and fail fast on a permanent 4xx.

## Async + the cloud-side queue

Create returns before the box exists; the cloud may also **queue** the
actuation under burst (many parallel jobs). The "wait until ready" step is what
makes this transparent — it polls the cloud for `RUNNING` (keyed by `cld-<id>`)
and then probes SSH. If a box never reaches `RUNNING` within the timeout, the
step fails loudly rather than letting a later step hit a phantom host.

## Gotchas worth remembering

- **Self-hosted runners are minimal.** Don't assume `gh`, `yq`, or `rsync`.
  We use curl + `python3` + `tar`, which are universally present, and fall back
  to GitHub's REST API when `gh` is missing (PR comments).
- **The debug-box SSH the PR comment prints needs a key the box trusts.** The
  CI keypair is throwaway (gone at job end), so a human debugger must be a
  registered collaborator with their own key on the box.
