# OpenSnell

A Go implementation of the Snell proxy protocol, versions **4** and **5** —
server-side and client-side, with **end-to-end interoperability against the
official Surge `snell-server v5.0.1`** verified for every code path below.

Snell v5's UDP/QUIC proxy mode is supported on the **server** only; pair it
with the **Surge** client (or any other v5-capable client) when you need
HTTP/3 acceleration for downstream applications.

### Why no v1 / v2 / v3?

This project deliberately drops support for the older Snell protocols.
Their stream framing predates the v4 padding/AEAD redesign and is at this
point trivially fingerprintable on the wire — in particular, traffic
patterns of v1/v2/v3 no longer reliably traverse the GFW and they
generally are not recommended for new deployments. If you have a legacy
v1/v2 setup you cannot retire yet, the sibling project
[open-snell](https://github.com/icpz/open-snell) (and its forks) still
implements those versions; this codebase focuses on the v4/v5 wire that
the current Surge `snell-server` speaks.

## Feature matrix

| Path                                  | `snell-server` | `snell-client` |
| ------------------------------------- | -------------- | -------------- |
| TCP CONNECT                           | ✅             | ✅             |
| TCP CONNECT with reuse (`CommandConnectV2`) | ✅       | ✅             |
| UDP-over-TCP (snell datagram)         | ✅             | ✅             |
| `http` / `tls` obfs                   | ✅             | ✅             |
| Dynamic Record Sizing (v5)            | ✅             | ✅             |
| `egress-interface` (v5)               | ✅             | —              |
| `ipv6` outbound family toggle (v5)    | ✅             | —              |
| **QUIC proxy mode (v5)**              | ✅             | use Surge      |

## Build

```sh
go build -o snell-server ./cmd/snell-server
go build -o snell-client ./cmd/snell-client
```

Or fetch directly:

```sh
go install github.com/missuo/opensnell/cmd/snell-server@latest
go install github.com/missuo/opensnell/cmd/snell-client@latest
```

## Server configuration

`snell-server.conf` — pass via `-c <path>`. All keys live under the
`[snell-server]` section.

```ini
[snell-server]

; Bind address(es). Required. Set to 0.0.0.0:<port> to accept from
; anywhere, or 127.0.0.1:<port> when fronted by another reverse proxy.
; When `quic = true` (default) the server also listens for UDP on the
; same port for QUIC proxy mode, so make sure both TCP/<port> and
; UDP/<port> are open in any firewall in front of the host.
listen = 0.0.0.0:8388

; Pre-shared key. Required. Treated as a raw UTF-8 string (NOT base64
; decoded) — keep this exactly as configured on the client side.
psk = your-shared-secret

; Obfuscation layer wrapping the snell stream. Optional, default off.
;   off  — no obfuscation (recommended; the v4/v5 frame format already
;          uses per-frame padding for traffic-shape obfuscation)
;   http — fake HTTP/1.1 Upgrade handshake
;   tls  — fake TLS ClientHello/ServerHello handshake
obfs = off

; Accept UDP-over-TCP from clients (snell's own datagram-in-stream
; protocol; distinct from QUIC mode below). Optional, default true.
udp = true

; QUIC proxy mode (v5). Optional, default true. When enabled, the
; server additionally listens on UDP/<port> from `listen` and accepts
; snell-encrypted envelopes that wrap a QUIC Initial packet; once the
; (src_ip, src_port) → upstream mapping is established, all subsequent
; UDP packets are forwarded as raw QUIC in both directions. Required
; for HTTP/3 acceleration with Surge clients that have `block-quic=off`.
quic = true

; Outbound interface binding. Optional, default empty (use the host's
; default routing). When set, all upstream sockets (TCP dials and
; UDP-over-TCP listeners and QUIC upstream dials) are pinned to this
; interface via SO_BINDTODEVICE on Linux or IP_BOUND_IF on macOS.
; Other platforms reject this at dial time.
egress-interface =

; Whether outbound dials may use IPv6 destinations. Optional, default
; true (matching the official Surge snell-server's `ipv6 = true`).
; When false, the dialer is constrained to "tcp4" / "udp4" — Go's
; resolver only considers A records and AAAA lookups are skipped.
; Useful on hosts whose IPv6 path is broken or slow. Only affects
; outbound; what addresses the server LISTENS on is still controlled
; by `listen` (write `[::]:8388` for v6 dual-stack inbound).
ipv6 = true
```

Run:

```sh
./snell-server -c snell-server.conf       # info level logs
./snell-server -c snell-server.conf -v    # debug level logs
```

A minimal systemd unit might look like:

```ini
[Unit]
Description=OpenSnell server
After=network.target

[Service]
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

## Client configuration

`snell-client.conf` exposes a local **SOCKS5** proxy (TCP CONNECT plus
UDP ASSOCIATE) and tunnels every accepted request through a snell server.
For QUIC/HTTP-3 use Surge as the front-end — this client is for tools
that already speak SOCKS5 (`curl --socks5-hostname`, browser proxy
settings, application SOCKS5 hooks, etc.).

```ini
[snell-client]

; Local SOCKS5 listener. Required. Bind to 127.0.0.1 unless you really
; mean to expose the proxy to the LAN.
listen = 127.0.0.1:1080

; Remote snell server, host:port. Required.
server = your-server.example.com:8388

; Pre-shared key, must match the server's `psk` byte-for-byte.
psk = your-shared-secret

; Snell protocol version this client claims to be. Optional, default v5.
;   v4 — explicit v4 client
;   v5 — explicit v5 client (recommended)
; v4 and v5 share the same TCP wire format, so this is informational
; today (logged at startup). The Surge v5 server is documented as
; backward-compatible with v4 clients.
version = v5

; Obfuscation layer. Optional, default off. Must match the server's
; setting. Valid values: off | http | tls.
obfs = off

; Host header / SNI used by the http/tls obfs layer. Optional, default
; is to reuse the server hostname.
obfs-host = bing.com

; Reuse upstream TCP connections across multiple SOCKS5 requests
; (snell's `CommandConnectV2`). Optional, default false. Recommended on
; for short HTTP requests; the pool caps each TCP at 2 sessions to
; match the real Surge server's behavior and drains the server's
; half-close zero chunk before putting a connection back so the next
; reuse starts on a clean frame boundary.
reuse = true
```

Run:

```sh
./snell-client -c snell-client.conf       # info level logs
./snell-client -c snell-client.conf -v    # debug level logs
```

### Example end-to-end smoke test

```sh
# In another terminal, with snell-client running on 127.0.0.1:1080:
curl -sS --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# Expect a body whose `ip=` line shows the snell-server's egress IP.
```

## Using OpenSnell server with Surge (recommended for QUIC/HTTP-3)

In your Surge config, add the server as a snell proxy with `version=5`
and disable Surge's per-connection QUIC block:

```ini
[Proxy]
my-snell = snell, your-server.example.com, 8388, psk=your-shared-secret, version=5, tfo=true, block-quic=off
```

When Surge dispatches an HTTP/3 connection through `my-snell`, it wraps
the first 1–2 QUIC Initial packets in the snell envelope (containing
the target SNI/host so it's hidden on the wire) and then forwards the
rest as raw QUIC — handled by `snell-server`'s `ServeQUIC` loop.

## Protocol notes

### TCP frame layout (v4 / v5)

- **Key derivation**: `argon2id(psk_utf8, salt, t=3, m=8 KiB, p=1)` →
  32 bytes; the first 16 are the AES-128-GCM key.
- Per-direction 16-byte random salt, sent once before the first frame.
- Each frame: a 7-byte plaintext header
  `[type=4, 0, 0, padLen_be, payloadLen_be]` is AEAD-sealed (nonce=N),
  followed by `padLen` bytes of padding and an AEAD-sealed payload
  (nonce=N+1). The nonce counter is a 12-byte little-endian increment.
- Bytes at even indices of the padding region are swapped with the
  leading bytes of the payload ciphertext (see `swapPadding`), so the
  raw padding bytes never appear contiguously on the wire.
- The first frame on every stream carries an extra `0x100..0x1FF`-byte
  padding chosen so the overall ones/zeros ratio of
  salt+padding+ciphertext stays within a "natural" range; later frames
  scale the maximum payload up from a small initial size to
  `MaxPayloadLength`, then reset after a 30 s idle window (this is
  v5's **Dynamic Record Sizing** optimization).

### QUIC envelope layout (v5 only, client → server, first packet of a flow)

```
[salt(16B random)]
[AEAD-Seal(K, nonce=0, [0x04, 0, 0, padLen_be, payloadLen_be]) || 16B tag]
[padding(padLen)]
[AEAD-Seal(K, nonce=1, request_header || inner_QUIC_packet) || 16B tag]

request_header = [0x01, 0x01, 0x00, hostlen, host, port_be]
K              = Argon2id(psk_utf8, salt, 3, 8 KiB, 1, 32)[:16]
AEAD           = AES-128-GCM
```

After the server decodes the first envelope and records the
`(client_src, upstream)` mapping, every subsequent UDP packet in either
direction is forwarded as **raw QUIC** with no additional snell framing.

This format was reverse-engineered against the official Surge
`snell-server v5.0.1` by capturing real HTTP/3 traffic from a Surge
client and decrypting with the configured PSK; see
`components/snell/quic.go` and `components/snell/quic_test.go` (the
unit test includes a real captured 1359-byte envelope as a fixture).

## Interop with the real Surge `snell-server`

Tested against `snell-server v5.0.1 (Nov 19 2025)`:

| Path                                | Result                                       |
| ----------------------------------- | -------------------------------------------- |
| Our client → real server, TCP       | ✅ 10/10                                      |
| Our client → real server, UDP-over-TCP | ✅ DNS round-tripped                       |
| Our client → real server, reuse     | ✅ 30 sequential + 20 parallel                |
| Our server, QUIC mode, real Surge envelope | ✅ unit test on a real capture          |
| HTTP/3 → our server → Cloudflare    | ✅ 5/5 (`ip=` echoes our server, `sni=plaintext`) |

## References

- [MetaCubeX/mihomo#2816](https://github.com/MetaCubeX/mihomo/pull/2816) —
  earlier reverse-engineered Snell v5 proposal (closed in favor of #2817);
  the description of the AEAD frame layout and padding interleave was the
  starting point for this implementation.
- [MetaCubeX/mihomo#2817](https://github.com/MetaCubeX/mihomo/pull/2817) —
  merged Snell v4/v5 outbound + inbound for mihomo; the TCP protocol
  layer here is a port of that code, adapted into a standalone
  server/client and stripped of v1/v2/v3 support.
- [Surge snell release notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) —
  upstream's published feature list per release.

## License

GPLv3 — see [LICENSE.md](LICENSE.md). Portions of the obfs, socks5, and
buffer-pool code originate from the open-snell / clash projects.
