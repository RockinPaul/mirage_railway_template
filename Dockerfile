# Mirage daemon — a virtual terminal for AI agents (https://github.com/strukto-ai/mirage)
#
# Upstream publishes the daemon as a Python package, not a container image; its only
# Dockerfile is a FUSE sandbox host that needs SYS_ADMIN and /dev/fuse, which Railway
# does not grant and the daemon does not need. This installs the package at a pinned
# version with the mountable backends and the Monty/QuickJS script runtimes.
FROM python:3.12-slim

ARG MIRAGE_VERSION=0.0.8
# Storage, data and messaging backends a workspace can mount, the Python (Monty) and
# JavaScript (QuickJS) runtimes for `python`/`node` inside the virtual shell, and the
# secret sources. Deliberately excluded: agent frameworks (the daemon serves agents, it
# does not run them), sandbox providers (daytona, e2b) and fuse.
ARG MIRAGE_EXTRAS=monty,quickjs,wasi,s3,r2,gcs,oci,postgres,mongodb,gridfs,redis,qdrant,chroma,lancedb,email,nextcloud,hf-buckets,langfuse,ssh,dotenv,aws-sm,1password

# socat: uvicorn cannot bind dual-stack (asyncio forces IPV6_V6ONLY on an IPv6 socket,
# and 0.0.0.0 is invisible on Railway's IPv6-only private network), so the daemon
# listens on loopback and socat relays a dual-stack :PORT to it. gosu/tini as usual.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git socat gosu tini \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "mirage-ai[${MIRAGE_EXTRAS}]==${MIRAGE_VERSION}" \
    && python -c "import mirage; print('mirage', mirage.__version__)" \
    && mirage --help >/dev/null

# `node`/`js` inside the virtual shell run on quickjs-ng compiled to WASI, executed
# in-process on wasmtime. The package does not ship the module; without it every
# `node` line fails with "the quickjs runtime needs a qjs-wasi.wasm module". Pinned
# and digest-checked here, and pointed at with MIRAGE_QUICKJS_HOME below.
ARG QJS_VERSION=v0.18.0
ARG QJS_SHA256=2c218412cb8b17e46ee91bea7556ec38f5b9b6bd6312fddd3ceeed14aa71eaaa
RUN set -eux; mkdir -p /opt/quickjs; \
    curl -fsSL -o /opt/quickjs/qjs-wasi.wasm \
        "https://github.com/quickjs-ng/quickjs/releases/download/${QJS_VERSION}/qjs-wasi.wasm"; \
    echo "${QJS_SHA256}  /opt/quickjs/qjs-wasi.wasm" | sha256sum -c -

# The daemon runs as a non-root user whose home is ON THE VOLUME, set in /etc/passwd
# (gosu resets HOME from passwd; an ENV-only home leaves the volume unused). -M because
# /data does not exist at build time; the entrypoint creates it.
RUN useradd -u 1000 -d /data/home -M -s /bin/bash mirage

# Constants are baked so no service variable can be nulled into a required composer
# field. The daemon's default disk state store is under MIRAGE_HOME/state, on the
# volume. The idle grace is ten years: the daemon SIGTERMs itself that long after its
# last workspace is removed, and a value of 0 means "exit immediately", so there is no
# way to disable it outright.
ENV PORT=8080 \
    MIRAGE_DAEMON_PORT=7000 \
    HOME=/data/home \
    MIRAGE_HOME=/data/mirage \
    MIRAGE_AUTH_MODE=token \
    MIRAGE_IDLE_GRACE_SECONDS=315360000 \
    MIRAGE_QUICKJS_HOME=/opt/quickjs \
    PYTHONUNBUFFERED=1

WORKDIR /data/home
EXPOSE 8080

COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-entrypoint
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/railway-entrypoint"]
