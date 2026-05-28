#!/bin/sh
# Renders /etc/snell-server/snell-server.conf from SNELL_* env vars, then execs snell-server.
set -eu

CONF_DIR="/etc/snell-server"
CONF_FILE="${CONF_DIR}/snell-server.conf"
mkdir -p "$CONF_DIR"

: "${SNELL_LISTEN:=0.0.0.0:2333}"
: "${SNELL_OBFS:=off}"
: "${SNELL_UDP:=true}"
: "${SNELL_QUIC:=true}"
: "${SNELL_IPV6:=true}"
: "${SNELL_TFO:=false}"
: "${SNELL_EGRESS_INTERFACE:=}"
: "${SNELL_DNS:=}"
: "${SNELL_PSK:=}"

if [ -z "$SNELL_PSK" ]; then
    SNELL_PSK="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"
    echo "[entrypoint] SNELL_PSK not set; generated PSK: ${SNELL_PSK}" >&2
fi

{
    echo "[snell-server]"
    echo "listen = ${SNELL_LISTEN}"
    echo "psk = ${SNELL_PSK}"
    echo "obfs = ${SNELL_OBFS}"
    echo "udp = ${SNELL_UDP}"
    echo "quic = ${SNELL_QUIC}"
    echo "ipv6 = ${SNELL_IPV6}"
    echo "tfo = ${SNELL_TFO}"
    [ -n "$SNELL_EGRESS_INTERFACE" ] && echo "egress-interface = ${SNELL_EGRESS_INTERFACE}"
    [ -n "$SNELL_DNS" ] && echo "dns = ${SNELL_DNS}"
} > "$CONF_FILE"

# If the first arg is `snell-server` (the default CMD), inject `-c <conf>`.
# Otherwise run whatever the user asked for verbatim.
if [ "${1:-}" = "snell-server" ]; then
    shift
    exec snell-server -c "$CONF_FILE" "$@"
fi
exec "$@"
