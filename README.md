# opensnell (v4/v5)

A Go implementation of the Snell protocol versions **4** and **5**, providing
both a server (`snell-server`) and a client (`snell-client`).

- Snell v5 server is wire-compatible with Snell v4 clients (no separate code
  path); both versions share the same AEAD frame format. See
  [evaluation notes](#protocol-notes).
- This project does **not** support Snell v1, v2, or v3.

## Build

```sh
go build ./cmd/snell-server
go build ./cmd/snell-client
```

## Configuration

Both binaries accept an ini config file via `-c`:

```ini
# snell-server.conf — the official snell-server has no `version` knob and
# silently ignores one if present; we do the same. The server always
# implements the v5 backend, which is documented backward-compatible with
# v4 clients.
[snell-server]
listen = 0.0.0.0:8388
psk    = your-shared-secret
obfs   = off          ; off | http | tls
udp    = true
egress-interface =    ; optional: bind upstream sockets to this interface
                      ; (Linux: SO_BINDTODEVICE; macOS: IP_BOUND_IF)
```

```ini
# snell-client.conf
[snell-client]
listen = 127.0.0.1:1080  ; local SOCKS5 listener
server = example.com:8388
psk    = your-shared-secret
obfs   = off
obfs-host = bing.com     ; only used with http/tls obfs
version = v5             ; v4 or v5 (default v5). Informational today —
                         ; v4 and v5 share the same TCP wire format; the
                         ; field is reserved for future QUIC routing.
reuse  = true            ; reuse upstream TCP connections
```

## Protocol notes

- Key derivation: `argon2id(psk, salt, t=3, m=8 KiB, p=1)` → 32 bytes, take
  the first 16 as the AES-128-GCM key.
- Per-direction 16-byte random salt, sent once before the first frame.
- Each frame: `AEAD-Seal(header = [type=4, 0, 0, paddingLen_be, payloadLen_be])`
  followed by `paddingLen` bytes of obfuscation padding and the AEAD-sealed
  payload. Bytes at even indices in the padding region are pre-swapped with
  the leading payload ciphertext bytes (see `swapPadding`).
- Initial frame carries an extra `0x100..0x1FF` byte padding generated such
  that the overall bit-count ratio of the salt+padding+ciphertext stays
  within a "natural" range.
- v5 currently behaves identically to v4 on the wire; the version byte
  inside the Snell command header is always `0x01` regardless.

## Interop with the real Surge `snell-server`

Tested against `snell-server v5.0.1 (Nov 19 2025)`:

| Path                               | Result                                |
| ---------------------------------- | ------------------------------------- |
| Client → real server, TCP CONNECT  | ✅ 10/10                              |
| Client → real server, UDP-over-TCP | ✅ DNS round-tripped                  |
| Client → real server, **reuse**    | ✅ 10/10 after fixing two reuse bugs (see below) |

### v5-specific server features status

- **Dynamic Record Sizing** — ✅ on parity. Our `v4Writer.nextPayloadLimit`
  starts the first frame small (so the salt + initial padding + payload
  fit in a single MTU) and ramps frame size up over the burst, then
  resets after a 30 s idle window.
- **`egress-interface`** — ✅ implemented. Set
  `egress-interface = <name>` in `snell-server.conf` to pin upstream
  TCP dials and the UDP-over-TCP listener to a specific local interface.
  Uses `SO_BINDTODEVICE` on Linux and `IP_BOUND_IF` / `IPV6_BOUND_IF`
  on macOS; other platforms surface a runtime error.
- **QUIC proxy mode** — ✅ implemented. Set `quic = true` (default) in
  `snell-server.conf` and the server will also listen on UDP/<port>
  alongside the TCP listener. The first 1–2 UDP packets from a new
  (src_ip, src_port) are expected to be a snell-encrypted envelope
  wrapping a QUIC Initial packet (which conveys the target host);
  subsequent packets in both directions are forwarded as raw QUIC
  using a per-flow (src ↔ upstream) mapping. The wire format was
  reverse-engineered against the official Surge `snell-server v5.0.1`
  by capturing real HTTP/3 traffic and decrypting with the configured
  PSK — see `components/snell/quic.go` for the layout. End-to-end
  HTTP/3 to cloudflare.com via our server passes round-trip 5/5,
  including the larger homepage HTML; the `EncodeQUICEnvelope` helper
  is exported so a third party can write a client.

### What the reuse fix looked like

Two bugs in the original port that surfaced only against real Surge
clients:

1. **`PoolConn.Read` dropped the snell zero-chunk as `(0, nil)` instead of
   `(0, io.EOF)`.** With the wrong shape, `io.CopyBuffer` would spin and
   only terminate via `SetReadDeadline` timeout — wasting an RTT and
   sometimes failing to consume the server's half-close frame at all.
2. **`PoolConn.Close` didn't drain the server's pending zero-chunk frame
   when the SOCKS5 client closed first** (typical for HTTP/1 short
   responses). The next pool reuse would then read the stale zero chunk
   on its first read, surface EOF to curl, and the TLS handshake would
   abort. Fix: in `PoolConn.Close`, drain remaining frames until the
   server's `ErrZeroChunk` is observed (or 500 ms timeout), and only
   put back if the drain completed cleanly.

The pool also caps each TCP at `maxUsesPerConn = 2` sessions, matching
the conservative behavior we saw from the real v5 server.

## References

- [MetaCubeX/mihomo#2816](https://github.com/MetaCubeX/mihomo/pull/2816) — earlier
  reverse-engineered Snell v5 proposal (closed in favor of #2817); the description
  of the AEAD frame layout and padding interleave was the starting point for this
  implementation.
- [MetaCubeX/mihomo#2817](https://github.com/MetaCubeX/mihomo/pull/2817) — merged
  Snell v4/v5 outbound + inbound for mihomo; the protocol layer here is a port of
  that code, adapted into a standalone server/client and stripped of v1/v2/v3
  support.

## License

GPLv3 — see [LICENSE.md](LICENSE.md). Portions of the obfs, socks5, and
buffer-pool code originate from the open-snell / clash projects.
