# Deploy and Host Mirage Daemon on Railway

[Mirage](https://github.com/strukto-ai/mirage) is a virtual terminal for AI agents: a bash-like
shell over a virtual filesystem that mounts object storage, databases, message platforms and
documents as directories, with git-style versioning of every workspace. This template runs the
Mirage daemon (0.0.6) as a token-protected service, so agents anywhere — your laptop, a CI job,
another Railway service — share one always-on workspace host.

## About Hosting Mirage

The daemon is a Python HTTP service, and upstream documents running it as a shared daemon with
an operator-issued bearer token. This template does exactly that and fixes the three things a
platform container needs on top: a dual-stack listener (the daemon's own server can only bind
one address family, and Railway's private network is IPv6-only), a Host allowlist built from your
Railway domains (the daemon rejects unknown hosts before it even checks the token), and a very
long idle grace (the daemon shuts itself down after its last workspace is removed, and that cannot
be turned off — only postponed). Workspace state, version history and snapshots live on a
volume.

## Common Use Cases

- Give a coding or research agent a shell over your S3 bucket, Postgres database, Notion pages or
  Slack channels, with every command recorded and every workspace versionable.
- Run agents from many places against one workspace host, instead of a daemon per laptop.
- Branch, commit and check out an agent's working state like code, and clone a workspace from a
  past version.

## Dependencies for Mirage Hosting

- A volume for the daemon's data root, which the template creates.
- Credentials for whatever your workspaces mount — S3 keys, a database URL, a Notion token — added
  to the service as variables your workspace config references. Nothing is required to deploy.

### Deployment Dependencies

- [Mirage](https://github.com/strukto-ai/mirage) — upstream project (Apache-2.0);
  [documentation](https://docs.mirage.strukto.ai).
- [quickjs-ng](https://github.com/quickjs-ng/quickjs) — the WASI build that runs `node`/`js`
  inside the shell (MIT).
- [Template repository](https://github.com/RockinPaul/mirage_railway_template) (MIT).

### Implementation Details

One service, `mirage`: `python:3.12-slim` with `mirage-ai` 0.0.6 installed with its storage, data
and messaging backends and the Monty (Python) and quickjs (JavaScript) runtimes; the quickjs-ng
0.18.0 WASI module pinned by digest. Health check `/v1/health`, which the daemon leaves open for
probes. Volume at `/data` holding the daemon home (`state/`, `repos/`, `snapshots/`). Runs as an
unprivileged user. The daemon binds loopback and a `socat` relay exposes it dual-stack on the
service port, so both the public edge and `mirage.railway.internal` reach it.

**Authentication** is upstream's token mode: every route except health requires
`Authorization: Bearer YOUR-MIRAGE-AUTH-TOKEN`; the token is generated per deployment and readable
from the service's variables. The entrypoint refuses to start without one.

**First run:** install the CLI (`pip install mirage-ai==0.0.6` or
`npm i -g @struktoai/mirage-cli`), point it at the service (`mirage config set url https://YOUR-DOMAIN`,
`export MIRAGE_TOKEN=…`), create a workspace from a YAML config and start executing. Use
`mode: exec` on a mount if the agent should run `python` or `node` scripts.

Three things to know. **Live workspaces are not reloaded after a redeploy**: the registry starts
empty, and you recreate a workspace by id and `checkout` a committed version — commits and
snapshots on the volume survive, uncommitted RAM state does not. **The shell is virtual**: its
commands are Mirage's own implementations over the mounts, and `python`/`node` are in-process
interpreters for small scripts, not a host OS. And upstream is at 0.0.x with a "preview" badge,
releasing every two to three weeks, so the pinned version moves.

## Why Deploy Mirage on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying Mirage on Railway, you are one step closer to supporting a complete full-stack
application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
