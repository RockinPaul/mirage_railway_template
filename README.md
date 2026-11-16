# Mirage Daemon on Railway

The [Mirage](https://github.com/strukto-ai/mirage) daemon — a virtual terminal for AI agents —
running as a token-protected service on Railway. Agents get a bash-like shell over a virtual
filesystem that can mount object storage, databases, message platforms and documents as
directories, with git-style versioning of every workspace. Your agents connect from anywhere with
one bearer token.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/mirage-daemon)

## Service

| Service | Runs | Public | Role |
|---|---|---|---|
| `mirage` | `mirage-ai` 0.0.6 on `python:3.12-slim`, socat relay, quickjs-ng 0.18.0 | **yes** | The daemon: workspaces, sessions, execute, jobs, versions — `/v1/*`. Data on `/data`. |

One service. The daemon speaks plain HTTP, so Railway's edge reaches it directly; the only extra
process is a `socat` relay that gives it a dual-stack listener (see below).

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `MIRAGE_AUTH_TOKEN` | generated | The bearer token every client presents. Read it from the service's variables. |
| `MIRAGE_EXTRA_HOSTS` | *(empty)* | Extra hostnames the daemon should accept, comma-separated — custom domains. |
| `MIRAGE_ALLOWED_HOSTS` | *(derived)* | Set this to take over the allowlist entirely (`*` accepts any host). |
| `MIRAGE_IDLE_GRACE_SECONDS` | `315360000` | Baked. See "It exits when idle" below. |
| `MIRAGE_AUTH_MODE` | `token` | Baked. `jwt` also works: set `MIRAGE_JWT_PUBKEY_FILE`/`MIRAGE_JWT_ALG` and change this. |
| `MIRAGE_HOME` | `/data/mirage` | Baked. `state/`, `repos/`, `snapshots/` live here, on the volume. |
| `MIRAGE_QUICKJS_HOME` | `/opt/quickjs` | Baked. Where `qjs-wasi.wasm` lives, so `node`/`js` work in the shell. |
| `PORT` / `MIRAGE_DAEMON_PORT` | `8080` / `7000` | Baked. Public relay port and the loopback port uvicorn binds. |

Provider credentials (S3 keys, a Postgres URL, a Notion token…) are not template fields: add
whatever your workspace configs reference as `${VAR}` to this service's variables.

## First run

Read `MIRAGE_AUTH_TOKEN` from the service's variables, then from your machine:

```bash
pip install 'mirage-ai==0.0.6'            # or: npm install -g @struktoai/mirage-cli
mirage config set url https://<your-domain>
export MIRAGE_TOKEN=<MIRAGE_AUTH_TOKEN>

cat > ws.yaml <<'YAML'
mounts:
  /:
    resource: ram
    mode: exec        # exec lets `python`/`node` run; `write` is files only
YAML
mirage workspace create ws.yaml --id demo
mirage execute -w demo -c 'echo hi > /hi.txt && cat /hi.txt'
mirage execute -w demo -c 'python -c "print(2**10)"'
mirage execute -w demo -c 'node -e "console.log(6*7)"'
mirage workspace commit demo -m "first"
```

Or speak HTTP directly: `POST /v1/workspaces` with `{"id":"demo","config":{"mounts":{"/":{"resource":"ram","mode":"exec"}}}}`,
then `POST /v1/workspaces/demo/execute` with `{"command":"ls /"}`, all with
`Authorization: Bearer <token>`. `GET /openapi.json` lists every route.

## How it fits together

- **Authentication is upstream's `token` mode.** Every route except `/v1/health` needs the
  bearer; a wrong or missing token is **401**, compared in constant time. The entrypoint refuses
  to start with an empty token or one shorter than 16 characters, because the alternative is an
  open remote shell over your mounted resources on a public URL.
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
  "exit immediately", so it cannot be switched off. `railway.json` also sets the restart policy
  to `ALWAYS`. If you shorten the grace, expect a cold restart every time the workspace count
  drops to zero.
- **What persists.** `MIRAGE_HOME` is on the volume: workspace state records, the git-backed
  version history and snapshots. **Live workspaces are not reloaded after a redeploy** — the
  registry starts empty. Recreate the workspace with the same id and `checkout` a committed
  version (or `load` a snapshot) to get your files back; uncommitted state in a `ram` mount is
  gone. Commit before you redeploy.
- **The shell is virtual.** `ls`, `cat`, `grep`, `curl`, `git`, `slack`, `ntn` and friends are
  implemented by Mirage over the VFS; there is no host shell, no `uname`, no `/etc/passwd`.
  `python` runs in-process on Monty and `node`/`js` on quickjs-ng under wasmtime — small scripts
  and pipe transforms, not a full interpreter. Both need the mount in `mode: exec`.
- **Runs as `mirage` (uid 1000)** with its home on the volume; the entrypoint is root only long
  enough to create the volume subdirectories beside Railway's `lost+found`.

## Not included

- **Stable releases.** Upstream is at 0.0.x with a "preview" badge and releases every 2–3 weeks.
- **FUSE / sandboxes.** Upstream's `docker/sandbox` image needs `SYS_ADMIN` and `/dev/fuse`,
  which Railway does not grant; the daemon does not need them. Sandbox providers (Daytona, E2B)
  and agent-framework extras are not installed — this service serves agents, it does not run
  them.
- **Network MCP.** `mirage mcp` speaks stdio only; run it next to your agent, not here.
- **Multi-tenancy.** One token, one operator. For per-user access switch to `jwt` mode.

## Upgrading

Bump `MIRAGE_VERSION` in the `Dockerfile` and push. Check the
[releases](https://github.com/strukto-ai/mirage/releases) — the daemon API, auth modes and
runtime plumbing are all young. quickjs-ng: bump `QJS_VERSION` and its digest.

## Files

```
Dockerfile       python:3.12-slim + mirage-ai[backends,runtimes] + socat + quickjs wasm
entrypoint.sh    fail-closed token check, volume prep, host allowlist, socat relay, gosu → uvicorn
railway.json     health check /v1/health, restart policy ALWAYS
```

## Licences

Mirage is [Apache-2.0](https://github.com/strukto-ai/mirage/blob/main/LICENSE); quickjs-ng is
MIT. The glue here is MIT.
