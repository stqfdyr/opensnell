# OpenSnell

[English](README.md) | 简体中文

OpenSnell 是 Snell 代理协议 **v4** 和 **v5** 的 Go 实现，包含服务端和
客户端。下文列出的每一条路径都已经与官方 Surge `snell-server v5.0.1`
完成端到端互操作性验证。

Snell v5 的 UDP/QUIC 代理模式目前仅在**服务端**支持；如果需要为下游
应用启用 HTTP/3 加速，请将本服务端与 **Surge** 客户端，或其他支持 v5
的客户端配合使用。

> **需要官方 Surge `snell-server` 没有的功能?**
> [`alpha`](https://github.com/missuo/opensnell/tree/alpha) 分支跟踪 `main`
> 并在其上叠加实验性的、非 Surge 官方的扩展 —— 目前包含 `tcp-brutal`
> 拥塞控制。`main` 分支保持与官方 server 的纯互操作语义;`alpha` 是我们
> 加 Surge 不带的功能的地方。

### 为什么不支持 v1 / v2 / v3？

本项目有意放弃了对早期 Snell 协议的支持。这些版本的流帧格式早于 v4
引入的 padding/AEAD 重新设计，如今在线路上已经很容易被指纹识别。尤其是
v1/v2/v3 的流量模式已经不能可靠穿越 GFW，因此通常不建议再用于新的部署。
如果你仍有暂时无法退役的 v1/v2 旧环境，可以使用同类项目
[open-snell](https://github.com/icpz/open-snell) 及其分支，它们仍然实现
这些版本；本代码库专注于当前 Surge `snell-server` 使用的 v4/v5 线路协议。

## 功能矩阵

| 路径                                  | `snell-server` | `snell-client` |
| ------------------------------------- | -------------- | -------------- |
| TCP CONNECT                           | ✅             | ✅             |
| 复用 TCP CONNECT（`CommandConnectV2`） | ✅             | ✅             |
| UDP-over-TCP（snell datagram）        | ✅             | ✅             |
| `http` / `tls` obfs                   | ✅             | ✅             |
| Dynamic Record Sizing（v5）           | ✅             | ✅             |
| `egress-interface`（v5）              | ✅             | —              |
| `ipv6` 出站地址族开关（v5）           | ✅             | —              |
| **QUIC 代理模式（v5）**               | ✅             | 使用 Surge     |

## 安装

### 一键服务端安装(Linux + systemd)

```sh
bash <(curl -fsSL https://s.ee/opensnell)
```

交互式安装器会:

- 让你选择 **OpenSnell**(默认,GPLv3,全平台)或者
  **官方 Surge `snell-server v5.0.1`**(闭源,仅 Linux)
- 留空 PSK 时用 `openssl` 自动生成
- 留空端口时在 `10000–60000` 范围内挑一个未被占用的随机端口
- 写 `/etc/snell/snell-server.conf`、安装 systemd unit
  (`snell-server.service`)、如果 UFW / firewalld 在跑就自动放行端口、
  启动服务
- 重跑可执行子命令:`reconfigure`、`update`、`uninstall`、`start`、
  `stop`、`restart`、`status`、`info` —— 详见 `./install.sh help`

### 从源码构建

```sh
go build -o snell-server ./cmd/snell-server
go build -o snell-client ./cmd/snell-client
```

也可以直接安装：

```sh
go install github.com/missuo/opensnell/cmd/snell-server@latest
go install github.com/missuo/opensnell/cmd/snell-client@latest
```

## 服务端配置

`snell-server.conf` 通过 `-c <path>` 传入。所有键都位于
`[snell-server]` 段内。

```ini
[snell-server]

; 监听地址。必填。设置为 0.0.0.0:<port> 表示接受任意来源的连接；
; 如果前面还有其他反向代理，则可以设置为 127.0.0.1:<port>。
; 当 `quic = true`（默认值）时，服务端还会在同一端口监听 UDP，
; 用于 QUIC 代理模式。因此，请确保主机前方的防火墙同时放行
; TCP/<port> 和 UDP/<port>。
listen = 0.0.0.0:2333

; 预共享密钥。必填。它会被当作原始 UTF-8 字符串处理，而不是
; 进行 base64 解码；请确保客户端配置中的值与这里完全一致。
psk = your-shared-secret

; 包裹 snell 流的混淆层。可选，默认关闭。
;   off  — 不启用混淆（推荐；v4/v5 帧格式已经使用逐帧 padding
;          对流量形态进行混淆）
;   http — 伪造 HTTP/1.1 Upgrade 握手
;   tls  — 伪造 TLS ClientHello/ServerHello 握手
obfs = off

; 是否接受来自客户端的 UDP-over-TCP（snell 自身的 datagram-in-stream
; 协议，与下方的 QUIC 模式不同）。可选，默认 true。
udp = true

; QUIC 代理模式（v5）。可选，默认 true。启用后，服务端会额外监听
; `listen` 中同一端口的 UDP，并接受包裹 QUIC Initial 数据包的
; snell 加密信封；一旦建立 `(src_ip, src_port) → upstream` 映射，
; 后续所有 UDP 数据包都会在两个方向上以原始 QUIC 形式转发。
; 如果需要配合设置了 `block-quic=off` 的 Surge 客户端实现 HTTP/3
; 加速，必须启用该选项。
quic = true

; 出站接口绑定。可选，默认留空（使用主机的默认路由）。设置后，
; 所有上游 socket，包括 TCP 拨号、UDP-over-TCP 监听器以及 QUIC
; 上游拨号，都会被绑定到该接口：Linux 使用 SO_BINDTODEVICE，
; macOS 使用 IP_BOUND_IF。其他平台会在拨号时拒绝该配置。
egress-interface =

; 出站拨号是否可以使用 IPv6 目标地址。可选，默认 true，与官方 Surge
; snell-server 的 `ipv6 = true` 一致。设置为 false 时，拨号器会被限制为
; "tcp4" / "udp4"；Go 的解析器只会考虑 A 记录，并跳过 AAAA 查询。
; 这适用于 IPv6 路径损坏或较慢的主机。该选项只影响出站连接；
; 服务端监听哪些地址仍由 `listen` 控制（如需 v6 双栈入站，请写
; `[::]:2333`）。
ipv6 = true
```

运行：

```sh
./snell-server -c snell-server.conf       # info 级别日志
./snell-server -c snell-server.conf -v    # debug 级别日志
```

一个最小的 systemd unit 可以写成：

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

## 客户端配置

`snell-client.conf` 会暴露一个本地 **SOCKS5** 代理（TCP CONNECT 加
UDP ASSOCIATE），并将每个已接受的请求通过 snell 服务端建立隧道。
如需使用 QUIC/HTTP-3，请将 Surge 作为前端；这个客户端面向已经支持
SOCKS5 的工具，例如 `curl --socks5-hostname`、浏览器代理设置以及应用内
SOCKS5 钩子等。

```ini
[snell-client]

; 本地 SOCKS5 监听地址。必填。除非确实想把代理暴露到局域网，
; 否则请绑定到 127.0.0.1。
listen = 127.0.0.1:1080

; 远端 snell 服务端，格式为 host:port。必填。
server = your-server.example.com:2333

; 预共享密钥，必须与服务端的 `psk` 逐字节一致。
psk = your-shared-secret

; 此客户端声明的 Snell 协议版本。可选，默认 v5。
;   v4 — 显式声明为 v4 客户端
;   v5 — 显式声明为 v5 客户端（推荐）
; v4 和 v5 共享相同的 TCP 线路格式，因此该字段目前只用于提供信息
; （启动时会写入日志）。Surge v5 服务端文档说明其向后兼容 v4 客户端。
version = v5

; 混淆层。可选，默认关闭。必须与服务端设置一致。有效值：
; off | http | tls。
obfs = off

; http/tls 混淆层使用的 Host header / SNI。可选，默认复用 server 主机名。
obfs-host = bing.com

; 是否在多个 SOCKS5 请求之间复用上游 TCP 连接
; （snell 的 `CommandConnectV2`）。可选，默认 false。短 HTTP 请求建议启用；
; 连接池会将每条 TCP 连接限制为最多 2 个会话，以匹配真实 Surge 服务端的
; 行为，并且在连接放回池之前排空服务端半关闭产生的 zero chunk，
; 确保下一次复用从干净的帧边界开始。
reuse = true
```

运行：

```sh
./snell-client -c snell-client.conf       # info 级别日志
./snell-client -c snell-client.conf -v    # debug 级别日志
```

### 端到端冒烟测试示例

```sh
# 另开一个终端，并确保 snell-client 正在 127.0.0.1:1080 上运行：
curl -sS --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# 预期响应正文中的 `ip=` 行会显示 snell-server 的出口 IP。
```

## 将 OpenSnell 服务端与 Surge 配合使用（推荐用于 QUIC/HTTP-3）

在 Surge 配置中，将该服务端添加为一个 snell 代理，设置 `version=5`，
并关闭 Surge 针对每条连接的 QUIC 阻断：

```ini
[Proxy]
my-snell = snell, your-server.example.com, 2333, psk=your-shared-secret, version=5, tfo=true, block-quic=off
```

当 Surge 通过 `my-snell` 分发 HTTP/3 连接时，它会将最初的 1 到 2 个
QUIC Initial 数据包包裹在 snell 信封中。该信封包含目标 SNI/host，因此
这些信息不会在线路上明文暴露。之后的其余数据包会以原始 QUIC 形式转发，
由 `snell-server` 的 `ServeQUIC` 循环处理。

## 协议说明

### TCP 帧布局（v4 / v5）

- **密钥派生**：`argon2id(psk_utf8, salt, t=3, m=8 KiB, p=1)` →
  32 字节；前 16 字节作为 AES-128-GCM 密钥。
- 每个方向都有一个 16 字节随机 salt，在第一帧之前发送一次。
- 每帧包含一个 7 字节明文头
  `[type=4, 0, 0, padLen_be, payloadLen_be]`，该头会被 AEAD 密封
  （nonce=N），随后是 `padLen` 字节 padding，以及被 AEAD 密封的 payload
  （nonce=N+1）。nonce 计数器是一个 12 字节小端递增值。
- padding 区域中偶数索引处的字节会与 payload 密文开头的字节交换
  （见 `swapPadding`），因此原始 padding 字节不会在线路上连续出现。
- 每条流的第一帧都会额外携带一段 `0x100..0x1FF` 字节的 padding，
  其长度会被选择为使 salt+padding+ciphertext 的整体 0/1 比例落在
  “自然”的范围内；后续帧会将最大 payload 从一个较小的初始大小逐步提升到
  `MaxPayloadLength`，并在 30 秒空闲窗口后重置。这就是 v5 的
  **Dynamic Record Sizing** 优化。

### QUIC 信封布局（仅 v5，client → server，一条流的第一个数据包）

```
[salt(16B random)]
[AEAD-Seal(K, nonce=0, [0x04, 0, 0, padLen_be, payloadLen_be]) || 16B tag]
[padding(padLen)]
[AEAD-Seal(K, nonce=1, request_header || inner_QUIC_packet) || 16B tag]

request_header = [0x01, 0x01, 0x00, hostlen, host, port_be]
K              = Argon2id(psk_utf8, salt, 3, 8 KiB, 1, 32)[:16]
AEAD           = AES-128-GCM
```

服务端解码第一个信封并记录 `(client_src, upstream)` 映射之后，两个方向上
后续的每个 UDP 数据包都会以**原始 QUIC**形式转发，不再附加任何 snell
帧封装。

该格式是通过抓取 Surge 客户端产生的真实 HTTP/3 流量，并使用配置中的 PSK
解密，与官方 Surge `snell-server v5.0.1` 对照逆向得到的；详见
`components/snell/quic.go` 和 `components/snell/quic_test.go`。单元测试中
包含一个真实抓取到的 1359 字节信封作为 fixture。

## 与真实 Surge `snell-server` 的互操作性

已针对 `snell-server v5.0.1 (Nov 19 2025)` 完成测试：

| 路径                                      | 结果                                             |
| ----------------------------------------- | ------------------------------------------------ |
| 我方客户端 → 真实服务端，TCP              | ✅ 10/10                                         |
| 我方客户端 → 真实服务端，UDP-over-TCP     | ✅ DNS 往返成功                                  |
| 我方客户端 → 真实服务端，复用             | ✅ 30 次串行 + 20 次并发                         |
| 我方服务端，QUIC 模式，真实 Surge 信封    | ✅ 基于真实抓包的单元测试通过                    |
| HTTP/3 → 我方服务端 → Cloudflare          | ✅ 5/5（`ip=` 回显我方服务端，`sni=plaintext`） |

## 参考资料

- [MetaCubeX/mihomo#2816](https://github.com/MetaCubeX/mihomo/pull/2816) —
  较早的 Snell v5 逆向提案，后来因 #2817 而关闭；其中对 AEAD 帧布局和
  padding 交错算法的描述是本实现的起点。
- [MetaCubeX/mihomo#2817](https://github.com/MetaCubeX/mihomo/pull/2817) —
  mihomo 合并的 Snell v4/v5 outbound + inbound 实现；这里的 TCP 协议层
  是从该代码移植而来，并改造为独立的服务端/客户端，同时移除了
  v1/v2/v3 支持。
- [Surge snell release notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) —
  上游按版本发布的功能列表。

## 许可证

GPLv3 — 见 [LICENSE.md](LICENSE.md)。obfs、socks5 和 buffer-pool 的部分
代码来自 open-snell / clash 项目。
