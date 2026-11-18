# Mirage Daemon on Railway

The [Mirage](https://github.com/strukto-ai/mirage) daemon — a virtual terminal for AI agents —
running as a token-protected service on Railway. Agents get a bash-like shell over a virtual
filesystem that can mount object storage, databases, message platforms and documents as
directories, with workspace snapshots and persistent session state. Your agents connect from anywhere with
one bearer token.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/mirage-daemon)

## Service

| Service | Runs | Public | Role |
|---|---|---|---|
| `mirage` | `mirage-ai` 0.0.8 on `python:3.12-slim`, socat relay, quickjs-ng 0.18.0 | **yes** | The daemon: workspaces, sessions, shell, VFS and snapshots — `/v1/*`. Data on `/data`. |

One service. The daemon speaks plain HTTP, so Railway's edge reaches it directly; the only extra
process is a `socat` relay that gives it a dual-stack listener (see below).

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `MIRAGE_AUTH_TOKEN` | generated | The bearer token every client presents. Read it from the service's variables. |
| `MIRAGE_EXTRA_HOSTS` | *(empty)* | Extra hostnames the daemon should accept, comma-separated — custom domains. |
| `MIRAGE_ALLOWED_HOSTS` | *(derived)* | Set this to take over the allowlist entirely (`*` accepts any host). |
| `MIRAGE_IDLE_GRACE_SECONDS` | `315360000` | Baked. See "It exits when idle" below. |
| `MIRAGE_AUTH_MODE` | `token` | Baked. One shared operator token; no per-user isolation. |
| `MIRAGE_HOME` | `/data/mirage` | Baked. The default disk state store lives under `state/`, on the volume. |
| `MIRAGE_QUICKJS_HOME` | `/opt/quickjs` | Baked. Where `qjs-wasi.wasm` lives, so `node`/`js` work in the shell. |
| `PORT` / `MIRAGE_DAEMON_PORT` | `8080` / `7000` | Baked. Public relay port and the loopback port uvicorn binds. |

Provider credentials (S3 keys, a Postgres URL, a Notion token…) are not template fields.
Export whatever your workspace configs reference as `${VAR}`. The CLI interpolates these from its own
environment before sending the config; server-side secret sources read the service environment.

## First run

Read `MIRAGE_AUTH_TOKEN` from the service's variables, then from your machine:

```bash
pip install 'mirage-ai==0.0.8'            # Python 3.12 or newer
mirage config set url https://YOUR-DOMAIN
export MIRAGE_TOKEN=YOUR-MIRAGE-AUTH-TOKEN

cat > ws.yaml <<'YAML'
mounts:
  /:
    vfs: ram
    mode: exec        # exec lets `python`/`node` run; `write` is files only
YAML
mirage workspace create ws.yaml --id demo
mirage shell -w demo -c 'echo hi > /hi.txt && cat /hi.txt'
mirage shell -w demo -c 'python -c "print(2**10)"'
mirage shell -w demo -c 'node -e "console.log(6*7)"'
mirage shell -w demo -c 'sleep 1 & wait; echo done'
mirage workspace snapshot demo demo.tar    # downloads to this machine
```

Or speak HTTP directly: `POST /v1/workspaces` with `{"id":"demo","config":{"mounts":{"/":{"vfs":"ram","mode":"exec"}}}}`,
then `POST /v1/workspaces/demo/shell` with `{"command":"ls /"}`, all with
`Authorization: Bearer YOUR-MIRAGE-AUTH-TOKEN`. The shell returns an IO result with `exit_code`,
`stdout` and `stderr`; `?stream=true` streams output. `GET /openapi.json` lists every route.
Each live workspace also exposes HTTP MCP at `/v1/workspaces/demo/mcp`, using the same bearer
token. `mirage mcp -w demo` remains available as a local stdio bridge.

Version 0.0.8 replaces the old `execute` and HTTP jobs APIs with `shell`. Background work uses
shell syntax (`command &`, `jobs`, `wait`, `kill`) within a session, rather than a jobs endpoint.
Use a matching 0.0.8 client. To restore the downloaded RAM files after a redeploy:

```bash
mirage workspace load demo.tar --id restored
mirage shell -w restored -c 'cat /hi.txt'
```

## How it fits together

- **Authentication is upstream's `token` mode.** Workspace operations need the
  bearer; a wrong or missing token is **401**, compared in constant time. The entrypoint refuses
  to start with an empty token or one shorter than 16 characters, because the alternative is an
  open remote shell over your mounted resources on a public URL.
  `/v1/health`, `/v1/ready` and OAuth protected-resource discovery are public.
- **The Host allowlist is enforced before auth, health check included.** A request whose `Host`
  is not on the list is **400 `Invalid host header`**, and an explicit list *replaces* the loopback
  defaults rather than extending them. The entrypoint builds the list from loopback, your Railway
  public and private domains and `MIRAGE_EXTRA_HOSTS`.
- **Dual-stack via socat.** uvicorn cannot bind both address families — asyncio forces
  `IPV6_V6ONLY` on an IPv6 socket, and `0.0.0.0` is invisible on Railway's IPv6-only private
  network. The daemon binds `127.0.0.1:7000`; `socat` listens dual-stack on `:8080` and relays
  TCP, so `Host` reaches the daemon untouched and the allowlist still applies. Sibling services
  can call `http://mirage.railway.internal:8080`.
- **It exits when idle — so the grace is ten years.** The daemon SIGTERMs itself
  `MIRAGE_IDLE_GRACE_SECONDS` after its last workspace is removed (exit 143), and `0` means
  "exit immediately", so it cannot be switched off. The template also sets the restart policy
  to `ALWAYS`. If you shorten the grace, expect a cold restart every time the workspace count
  drops to zero.
- **What persists.** The daemon supplies a disk state store under `MIRAGE_HOME/state` unless
  the workspace config specifies its own store. After close/recreate or a container replacement,
  recreate with the same config and id: session working directory and exported variables return,
  but files in a `ram` mount do not. The live registry starts empty after a restart. Download a
  snapshot before stopping to retain RAM files, then `workspace load` it; `workspace close` keeps
  stored session state, whereas `workspace delete` removes it. Snapshot files are downloaded to
  the client; this template does not configure the S3 snapshot store required by `--key`.
- **The shell is virtual.** `ls`, `cat`, `grep`, `curl`, `git`, `slack`, `ntn` and friends are
  implemented by Mirage over the VFS; there is no host shell, no `uname`, no `/etc/passwd`.
  The default runtime list is `monty`, `quickjs`, `workspace`: `python` runs in Monty's
  pooled worker subprocesses and `node`/`js` on quickjs-ng under wasmtime — small scripts
  and pipe transforms, without full CPython or Node.js APIs. Both need the mount in `mode: exec`.
- **Runs as `mirage` (uid 1000)** with its home on the volume; the entrypoint is root only long
  enough to create the volume subdirectories beside Railway's `lost+found`.

## Not included

- **Stable releases.** Upstream is at 0.0.x with a "preview" badge and releases every 2–3 weeks.
- **FUSE / sandboxes.** Upstream's `docker/sandbox` image needs `SYS_ADMIN` and `/dev/fuse`,
  which Railway does not grant; the daemon does not need them. Sandbox providers (Daytona, E2B)
  and agent-framework extras are not installed — this service serves agents, it does not run
  them.
- **Multi-tenancy.** Shared-token requests have no account identity. Every holder has the same
  access; JWT account ownership rules do not isolate users of this template's shared token.

## Upgrading

Bump `MIRAGE_VERSION` in the `Dockerfile` and push. Check the
[releases](https://github.com/strukto-ai/mirage/releases) — the daemon API, auth modes and
runtime plumbing are all young. quickjs-ng: bump `QJS_VERSION` and its digest.

## Files

```
Dockerfile       python:3.12-slim + mirage-ai[backends,runtimes] + socat + quickjs wasm
entrypoint.sh    fail-closed token check, volume prep, host allowlist, socat relay, gosu → uvicorn
```

## Licences

Mirage is [Apache-2.0](https://github.com/strukto-ai/mirage/blob/main/LICENSE); quickjs-ng is
MIT. The glue here is MIT.
