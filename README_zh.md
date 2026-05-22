# OpenSnell

[English](README.md) | 简体中文

Snell 代理协议的 Go 实现,支持 **v4** 与 **v5** 两个版本 —— 同时实现了
服务端和客户端,**端到端互操作性已对照官方 Surge `snell-server v5.0.1`
逐条路径验证通过**。

Snell v5 的 UDP/QUIC 代理模式**仅在服务端**实现;当你需要 HTTP/3 加速
时,把它和 **Surge** 客户端(或任何其他支持 v5 的客户端)配合使用即可。

### 为什么不支持 v1 / v2 / v3?

本项目主动放弃了对旧版 Snell 协议的支持。这些版本的流式帧格式早于 v4
的 padding/AEAD 改造,在线缆上已经可以被轻易指纹识别 —— 尤其是
**v1/v2/v3 的流量特征目前已经不能稳定穿透 GFW**,不推荐用于新部署。
如果你有暂时还无法下线的 v1/v2 老部署,可以去看 sibling 项目
[open-snell](https://github.com/icpz/open-snell)(及其各种 fork),
那里仍然实现着这些老版本;本仓库的代码只关注当前 Surge `snell-server`
所使用的 v4/v5 wire format。

## 功能矩阵

| 路径                                   | `snell-server` | `snell-client` |
| -------------------------------------- | -------------- | -------------- |
| TCP CONNECT                            | ✅              | ✅              |
| TCP CONNECT 复用(`CommandConnectV2`)| ✅              | ✅              |
| UDP-over-TCP(snell 自己的 datagram)  | ✅              | ✅              |
| `http` / `tls` obfs 混淆               | ✅              | ✅              |
| 动态记录大小 Dynamic Record Sizing(v5)| ✅            | ✅              |
| `egress-interface` 出口接口绑定(v5)  | ✅              | —              |
| `ipv6` 出向地址族开关(v5)            | ✅              | —              |
| **QUIC 代理模式(v5)**                | ✅              | 用 Surge       |

## 构建

```sh
go build -o snell-server ./cmd/snell-server
go build -o snell-client ./cmd/snell-client
```

或者直接拉取:

```sh
go install github.com/missuo/opensnell/cmd/snell-server@latest
go install github.com/missuo/opensnell/cmd/snell-client@latest
```

## 服务端配置

`snell-server.conf` —— 通过 `-c <path>` 传入。所有 key 都在
`[snell-server]` 这个 section 下。

```ini
[snell-server]

; 监听地址。必填。设成 0.0.0.0:<port> 接受任意来源,或 127.0.0.1:<port>
; 当前面有反向代理。当 `quic = true`(默认)时,服务端会**同时**在
; 同一端口监听 UDP 走 QUIC 代理模式,所以请确保前置防火墙的
; TCP/<port> 和 UDP/<port> 都开了。
listen = 0.0.0.0:8388

; 预共享密钥。必填。**当作原始 UTF-8 字符串处理(不做 base64 解码)**,
; 必须与客户端那一侧完全一致。
psk = your-shared-secret

; snell 流外面再包一层混淆。可选,默认 off。
;   off  —— 不混淆(推荐;v4/v5 帧格式自己就有 per-frame padding 做流量
;         整形混淆)
;   http —— 伪装成 HTTP/1.1 Upgrade 握手
;   tls  —— 伪装成 TLS ClientHello/ServerHello 握手
obfs = off

; 是否接受 UDP-over-TCP 请求(snell 自己的 datagram-in-stream 协议;
; 跟下面的 QUIC 模式是不同的两件事)。可选,默认 true。
udp = true

; QUIC 代理模式(v5)。可选,默认 true。开启后服务端会同时在 `listen`
; 指定的端口上听 UDP,接受用 snell 加密、内部封装 QUIC Initial 包的
; envelope;一旦 `(src_ip, src_port) → 上游` 的映射建立,后续所有
; UDP 包就在两个方向上以**裸 QUIC**形式直接转发。如果你的 Surge
; 客户端设了 `block-quic=off`、要走 HTTP/3 加速,**必须开启这个**。
quic = true

; 出口接口绑定。可选,默认空(走宿主机默认路由)。设置后,所有上游
; socket(TCP 拨号、UDP-over-TCP 监听、QUIC 上游拨号)都会被绑到指定
; 接口 —— Linux 用 SO_BINDTODEVICE,macOS 用 IP_BOUND_IF。其他平台
; 在拨号时直接报错。
egress-interface =

; 出向拨号是否允许走 IPv6 目标地址。可选,默认 true(跟官方 Surge
; snell-server 的 `ipv6 = true` 一致)。设成 false 后,dialer 被
; 限制为 "tcp4" / "udp4" —— Go 的 resolver 只看 A 记录、不查 AAAA,
; AAAA-only 的目标会以"no such host"拒绝。在 IPv6 路径异常或慢的
; 宿主机上很有用。**只影响出向**;服务端**监听**哪些地址仍然由
; `listen` 字段控制(想要 v6 dual-stack 入向就写 `[::]:8388`)。
ipv6 = true
```

启动:

```sh
./snell-server -c snell-server.conf       # info 级别日志
./snell-server -c snell-server.conf -v    # debug 级别日志
```

一个最小化的 systemd unit 大概长这样:

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

`snell-client.conf` 在本地开一个 **SOCKS5** 代理(TCP CONNECT + UDP
ASSOCIATE),把进来的每个请求隧道化转发到 snell 服务端。要走
QUIC/HTTP-3 请用 Surge 当前端 —— 这个 client 是给那些**已经会说
SOCKS5** 的工具用的(`curl --socks5-hostname`、浏览器代理设置、
应用内的 SOCKS5 钩子等等)。

```ini
[snell-client]

; 本地 SOCKS5 监听地址。必填。除非你真的要把代理暴露到局域网,
; 否则保持 127.0.0.1。
listen = 127.0.0.1:1080

; 远端 snell 服务端,host:port 格式。必填。
server = your-server.example.com:8388

; 预共享密钥,必须与服务端的 `psk` 逐字节一致。
psk = your-shared-secret

; 这个 client 自称的 Snell 协议版本。可选,默认 v5。
;   v4 —— 显式 v4 客户端
;   v5 —— 显式 v5 客户端(推荐)
; v4 和 v5 共用同一套 TCP wire format,所以这个字段今天只是
; 信息性的(启动时会打到日志里)。Surge v5 服务端在文档里明确
; 声明对 v4 客户端向后兼容。
version = v5

; 混淆层。可选,默认 off。必须与服务端设置一致。合法值:off | http | tls。
obfs = off

; http/tls 混淆使用的 Host header / SNI。可选,默认复用 server 主机名。
obfs-host = bing.com

; 是否在多次 SOCKS5 请求之间复用上游 TCP 连接(snell 的
; `CommandConnectV2`)。可选,默认 false。对短 HTTP 请求建议开;
; 连接池每条 TCP 最多承载 2 次会话(与真实 Surge 服务端的行为
; 一致),并在把连接放回池前**主动 drain 服务端的半关闭 zero
; chunk**,这样下一次复用从一个干净的帧边界开始。
reuse = true
```

启动:

```sh
./snell-client -c snell-client.conf       # info 级别日志
./snell-client -c snell-client.conf -v    # debug 级别日志
```

### 端到端冒烟测试示例

```sh
# 另起一个终端,前提:snell-client 已经在 127.0.0.1:1080 上跑起来了。
curl -sS --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# 正确的话,响应里 `ip=` 那一行会显示 snell-server 的出口 IP。
```

## 把 OpenSnell 服务端和 Surge 配合使用(走 QUIC/HTTP-3 推荐这么做)

在 Surge 配置里,把这台服务端加成一个 snell proxy,显式 `version=5`,
并关闭 Surge 的逐连接 QUIC 阻断:

```ini
[Proxy]
my-snell = snell, your-server.example.com, 8388, psk=your-shared-secret, version=5, tfo=true, block-quic=off
```

当 Surge 把一个 HTTP/3 连接派发到 `my-snell` 时,它会把前 1–2 个
QUIC Initial 包封装在 snell envelope 里(envelope 内部携带目标
SNI/host,这样在线缆上不会泄漏),后续 QUIC 包以裸格式继续转发 ——
这套流程由 `snell-server` 的 `ServeQUIC` 循环处理。

## 协议说明

### TCP 帧布局(v4 / v5)

- **密钥派生**:`argon2id(psk_utf8, salt, t=3, m=8 KiB, p=1)` → 32 字节,
  取前 16 字节作为 AES-128-GCM 密钥。
- 每个方向各有一个 16 字节随机 salt,在第一个帧之前发送一次。
- 每帧结构:7 字节明文 header
  `[type=4, 0, 0, padLen_be, payloadLen_be]` 用 AEAD 封装(nonce=N),
  后面跟 `padLen` 字节的 padding,再后面是 AEAD 封装的 payload
  (nonce=N+1)。nonce 计数器是 12 字节小端递增。
- padding 区域中偶数下标的字节会被和 payload 密文开头的字节
  对换位置(见 `swapPadding`),这样 padding 字节永远不会在线缆上
  以原始连续形式出现。
- 每条流的第一帧额外携带一段 `0x100..0x1FF` 字节的 padding,
  选取的方式让 salt+padding+ciphertext 的整体 0/1 比保持在一个
  "自然"的范围里;后续帧的最大 payload 长度从一个较小的初始值
  逐步爬升到 `MaxPayloadLength`,空闲 30 秒后重置(这就是 v5 的
  **Dynamic Record Sizing** 优化)。

### QUIC envelope 布局(仅 v5,client → server,一条 flow 的第一个包)

```
[salt(16B 随机)]
[AEAD-Seal(K, nonce=0, [0x04, 0, 0, padLen_be, payloadLen_be]) || 16B tag]
[padding(padLen)]
[AEAD-Seal(K, nonce=1, request_header || inner_QUIC_packet) || 16B tag]

request_header = [0x01, 0x01, 0x00, hostlen, host, port_be]
K              = Argon2id(psk_utf8, salt, 3, 8 KiB, 1, 32)[:16]
AEAD           = AES-128-GCM
```

服务端解码第一个 envelope、把 `(client_src, upstream)` 映射记下来
之后,两个方向上后续的所有 UDP 包都以**裸 QUIC**形式转发,不再加任何
snell framing。

这套格式是我们对照官方 Surge `snell-server v5.0.1`、从 Surge 客户端
抓真实 HTTP/3 流量、用已知 PSK 反推出来的;详见
`components/snell/quic.go` 和 `components/snell/quic_test.go`(单元
测试里有一条 1359 字节的真实抓包 envelope 作 fixture)。

## 与真实 Surge `snell-server` 的互操作性

针对 `snell-server v5.0.1 (Nov 19 2025)` 的实测结果:

| 路径                                              | 结果                                              |
| ------------------------------------------------- | ------------------------------------------------- |
| 我们的 client → 真实 server,TCP                  | ✅ 10/10                                           |
| 我们的 client → 真实 server,UDP-over-TCP         | ✅ DNS 查询往返成功                                |
| 我们的 client → 真实 server,reuse 复用模式       | ✅ 30 串行 + 20 并发                               |
| 我们的 server 解码真实 Surge envelope             | ✅ 单元测试基于一次真实抓包通过                    |
| HTTP/3 → 我们的 server → Cloudflare               | ✅ 5/5(`ip=` 显示我们 server 出口,`sni=plaintext`)|

## 参考资料

- [MetaCubeX/mihomo#2816](https://github.com/MetaCubeX/mihomo/pull/2816) ——
  更早的 Snell v5 反推提案(后来被 #2817 取代而关闭);其中对 AEAD 帧布局
  和 padding 交错算法的描述,是本实现的起点。
- [MetaCubeX/mihomo#2817](https://github.com/MetaCubeX/mihomo/pull/2817) ——
  mihomo 合入的 Snell v4/v5 outbound + inbound 实现;本项目的 TCP 协议
  层是从这份代码移植过来的,改造成独立的 server/client,并裁掉了
  v1/v2/v3 支持。
- [Surge snell release notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) ——
  上游官方按版本发布的功能清单。

## 许可证

GPLv3 —— 见 [LICENSE.md](LICENSE.md)。obfs、socks5、buffer pool 部分的
代码源自 open-snell / clash 项目。
