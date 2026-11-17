# Deploy and Host Mirage Daemon on Railway

[Mirage](https://github.com/strukto-ai/mirage) is a virtual terminal for AI agents: a bash-like
shell over a virtual filesystem that mounts object storage, databases, message platforms and
documents as directories, with workspace snapshots and persistent session state. This template runs the
Mirage daemon (0.0.8) as a token-protected service, so agents anywhere — your laptop, a CI job,
another Railway service — share one always-on workspace host.

## About Hosting Mirage

The daemon is a Python HTTP service, and upstream documents running it as a shared daemon with
an operator-issued bearer token. This template does exactly that and fixes the three things a
platform container needs on top: a dual-stack listener (the daemon's own server can only bind
one address family, and Railway's private network is IPv6-only), a Host allowlist built from your
Railway domains (the daemon rejects unknown hosts before it even checks the token), and a very
long idle grace (the daemon shuts itself down after its last workspace is removed, and that cannot
be turned off — only postponed). The default disk session state store lives on a volume;
RAM files need a downloaded snapshot to survive a restart.

## Common Use Cases

- Give a coding or research agent a shell over your S3 bucket, Postgres database, Notion pages or
  Slack channels, with command history and downloadable workspace snapshots.
- Run agents from many places against one workspace host, instead of a daemon per laptop.
- Clone a workspace's live state or download and restore a snapshot of its files.

## Dependencies for Mirage Hosting

- A volume for the daemon's data root, which the template creates.
- Credentials for whatever your workspaces mount — S3 keys, a database URL, a Notion token — added
  to the CLI environment for `${VAR}` interpolation, or to the service for server-side secret
  sources. Nothing is required to deploy.

### Deployment Dependencies

- [Mirage](https://github.com/strukto-ai/mirage) — upstream project (Apache-2.0);
  [documentation](https://docs.mirage.strukto.ai).
- [quickjs-ng](https://github.com/quickjs-ng/quickjs) — the WASI build that runs `node`/`js`
  inside the shell (MIT).
- [Template repository](https://github.com/RockinPaul/mirage_railway_template) (MIT).

### Implementation Details

One service, `mirage`: `python:3.12-slim` with `mirage-ai` 0.0.8 installed with its storage, data
and messaging backends and the Monty (Python, pooled worker subprocesses) and QuickJS (JavaScript)
runtimes; the quickjs-ng
0.18.0 WASI module pinned by digest. Health check `/v1/health`, which the daemon leaves open for
probes. Volume at `/data` holding the daemon home and its `state/` store. Runs as an
unprivileged user. The daemon binds loopback and a `socat` relay exposes it dual-stack on the
service port, so both the public edge and `mirage.railway.internal` reach it.

**Authentication** is upstream's token mode: workspace operations require
`Authorization: Bearer YOUR-MIRAGE-AUTH-TOKEN`; the token is generated per deployment and readable
from the service's variables. Health, readiness and OAuth protected-resource discovery are public.
The entrypoint refuses to start without a token. Each live workspace also serves HTTP MCP at
`/v1/workspaces/YOUR-WORKSPACE-ID/mcp` with the same bearer token.

**First run:** install the matching CLI (`pip install mirage-ai==0.0.8`, Python 3.12+),
point it at the service (`mirage config set url https://YOUR-DOMAIN`,
`export MIRAGE_TOKEN=YOUR-MIRAGE-AUTH-TOKEN`), and create a workspace:

```yaml
mounts:
  /:
    vfs: ram
    mode: exec
```

Save that as `ws.yaml`, run `mirage workspace create ws.yaml --id demo`, then
`mirage shell -w demo -c 'echo hi > /hi.txt && cat /hi.txt'`. Mounts now use `vfs`,
and `shell` replaces the removed execute/jobs APIs. Background commands use `command &`,
`jobs`, `wait` and `kill` inside the shell. `mode: exec` permits `python` (Monty) and
`node` (QuickJS); the default runtime list is `monty`, `quickjs`, `workspace`.

Three things to know. **The live registry starts empty after a redeploy**: recreate with the
same config and id to restore session state (working directory and exported variables).
Close/recreate and container replacement do not retain RAM files: download them first with
`mirage workspace snapshot demo demo.tar`, then restore with
`mirage workspace load demo.tar --id restored`. `workspace close` keeps stored session state;
`workspace delete` removes it. There is no server-side S3 snapshot store configured for `--key`.
**Shared-token mode is one operator**, without account isolation. **The shell is virtual**: its
commands are Mirage's own implementations over the mounts, and `python`/`node` are sandboxed
interpreters for small scripts, without full CPython or Node.js APIs. And upstream is at 0.0.x with a "preview" badge,
releasing every two to three weeks, so the pinned version moves.

## Why Deploy Mirage on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying Mirage on Railway, you are one step closer to supporting a complete full-stack
application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
