#!/bin/sh
set -eu

# Fail closed: token mode with no token would be an open remote shell over your
# mounted resources on a public URL. Upstream's local mode mints a token into a file
# the deployer could never read; a Railway secret is the right source here.
if [ -z "${MIRAGE_AUTH_TOKEN:-}" ]; then
    echo "FATAL: MIRAGE_AUTH_TOKEN is empty. Set it on this service (the template generates one)." >&2
    exit 1
fi
if [ "${#MIRAGE_AUTH_TOKEN}" -lt 16 ]; then
    echo "FATAL: MIRAGE_AUTH_TOKEN is ${#MIRAGE_AUTH_TOKEN} characters; use at least 16." >&2
    exit 1
fi

# Railway mounts the volume root-owned with a lost+found directory, so everything
# lives in subdirectories, created here and handed to the unprivileged user.
mkdir -p "${HOME}" "${MIRAGE_HOME}"
if [ ! -e "${HOME}/.bashrc" ]; then cp -a /etc/skel/. "${HOME}/" 2>/dev/null || true; fi
chown -R mirage:mirage "${HOME}" "${MIRAGE_HOME}"

# The daemon rejects any Host header outside its allowlist with 400, health check
# included, and an explicit list REPLACES the loopback defaults. Trust the public and
# private Railway domains, loopback, and anything in MIRAGE_EXTRA_HOSTS (custom
# domains, comma-separated). MIRAGE_ALLOWED_HOSTS set explicitly wins outright.
if [ -z "${MIRAGE_ALLOWED_HOSTS:-}" ]; then
    hosts="127.0.0.1,localhost,::1"
    [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]  && hosts="${hosts},${RAILWAY_PUBLIC_DOMAIN}"
    [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ] && hosts="${hosts},${RAILWAY_PRIVATE_DOMAIN}"
    [ -n "${MIRAGE_EXTRA_HOSTS:-}" ]     && hosts="${hosts},${MIRAGE_EXTRA_HOSTS}"
    export MIRAGE_ALLOWED_HOSTS="${hosts}"
fi

echo "mirage: daemon on 127.0.0.1:${MIRAGE_DAEMON_PORT}, dual-stack relay on :${PORT}, data in ${MIRAGE_HOME}"
echo "mirage: allowed hosts ${MIRAGE_ALLOWED_HOSTS}"
echo "mirage: clients -> mirage config set url https://${RAILWAY_PUBLIC_DOMAIN:-<your-domain>} ; export MIRAGE_TOKEN=<MIRAGE_AUTH_TOKEN>"

# uvicorn binds loopback; socat exposes a dual-stack listener so both Railway's edge
# (IPv4) and the private network (IPv6) reach it. socat is a TCP relay, so the Host
# header arrives at the daemon untouched and the allowlist above still applies.
gosu mirage socat "TCP6-LISTEN:${PORT},ipv6only=0,fork,reuseaddr" "TCP4:127.0.0.1:${MIRAGE_DAEMON_PORT}" &

cd "${MIRAGE_HOME}"
exec gosu mirage python -m uvicorn mirage.server.daemon:app \
    --host 127.0.0.1 --port "${MIRAGE_DAEMON_PORT}" --proxy-headers "$@"
