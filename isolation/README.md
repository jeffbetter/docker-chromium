# 隔离浏览器 overlay（Trojan 硬出口 + 网络层 kill-switch）

本目录是 **jlesage/docker-chromium 的 Compose 叠加层**，不改上游镜像构建、不改 `rootfs/`。
目标：在 **美国 Linux 服务器** 上按身份启动独立 Chromium 桌面，每个身份使用自己的持久 `/config`（Cookie / 下载），流量只走 **该身份自己的 Trojan 上游**；代理断开时 **不得直连回落**（含 DNS、IPv6、UDP/WebRTC）。

远端只通过 **本机回环上的 SSH 隧道** 使用原生 VNC。本仓库 **不会** 登录 Gmail / Yahoo / Claude，也 **不会** 在用户服务器上实际部署。

当前仓库提交与上游对齐：`cfadd2501f6ae2b72bd36b10008dfe68100b6896`（镜像建议钉死 `jlesage/chromium:v26.10.1`，对应 Chromium `155.0.8059.84-r0`）。

---

## 明确做不到的事（不要自行脑补）

- **不会** 因为开了两个容器就得到两个公网 IP。相同 Trojan 出口 = 相同出口 IP。`validate-exits.sh` 只检查配置是否重复，**不探测** 真实出口 IP。
- **不会** 承诺账号不可关联。浏览器指纹、字体、时区、登录行为、同一 Trojan 基础设施，都可以把身份联系起来。需要不同公网 IP 时，必须使用 **真正不同的代理出口**。
- **不会** 在本环境验证「现在的出口 IP 是多少」或任何站点登录态。凡是 live IP / 登录相关的事实，下文一律标为 **未验证**。
- 仅共享 Docker 网络命名空间 **不是** kill-switch。没有 nft/默认路由删除/DNS 覆盖时，代理一挂就可能从 `eth0` 漏出去。

---

## 核心选择：为什么是 sing-box，而不是原版 Trojan 或 mihomo

对照了三份「官方/现行」材料：

| 实现 | 状态 | 与本需求 |
| --- | --- | --- |
| [trojan-gfw/trojan](https://github.com/trojan-gfw/trojan) `examples/client.json-example` | 最后正式版 v1.16.0（2020-06-10），维护分 0/10 | 字段是权威协议参考（`remote_addr` / `password` / `ssl.verify=true` / `ssl.sni` / `ssl.alpn`），但 **不再适合当运行时** |
| [sing-box](https://sing-box.sagernet.org/) v1.14.4（当前 latest 稳定） | 持续维护；官方镜像 `ghcr.io/sagernet/sing-box:v1.14.4`；[Trojan outbound](https://sing-box.sagernet.org/configuration/outbound/trojan/) 与 [TUN `strict_route`](https://sing-box.sagernet.org/configuration/inbound/tun/) | **采用**。一对一映射 Trojan 字段；TUN + `strict_route` 专为「不支持的路径变 unreachable」；固定单出口，不需要 Clash 规则生态。GitHub release 的 linux tarball 是 glibc 链接，不能直接放进 Alpine |
| [mihomo](https://wiki.metacubex.one/) | 同样维护；Trojan 节点 + TUN `strict-route` | 可用，但文档示例默认 `skip-cert-verify: true`，且规则引擎面向分流。本 overlay 是 **单身份、固定出口、必须校验证书**，用它没有额外收益 |

字段映射（保持 SNI 与证书校验，**禁止** `tls.insecure=true`）：

| 原版 Trojan client | 本 overlay（sing-box） |
| --- | --- |
| `remote_addr` / `remote_port` | `outbounds[].server` / `server_port`（启动时解析成 IPv4 后写入，避免 Docker DNS 泄漏） |
| `password[]` | `password` |
| `ssl.sni` | `tls.server_name`（必填；`disable_sni=false`） |
| `ssl.verify` / `ssl.verify_hostname` | `tls.insecure=false` |
| `ssl.alpn` | `tls.alpn`（默认 `h2,http/1.1`） |
| `ssl.cert` | 可选 `TROJAN_CERTIFICATE_PATH` → `tls.certificate_path` |

TUN 使用 `auto_route=true`、`strict_route=true`，**关闭** `auto_redirect`：后者会改 nftables，可能和独立 kill-switch 抢表。Docker 网桥冲突靠「先删默认路由 + 只给 Trojan IP 留 host route + 进程绑定 `bind_interface`」处理，而不是把策略交给 auto_redirect。

---

## 架构

每个身份一个 Compose 项目：`iso-<identity>`。

```
笔记本 VNC 客户端
    |  ssh -L 127.0.0.1:5901:127.0.0.1:5901
美国 Linux 宿主机 127.0.0.1:5901  (compose 只发布到 loopback)
    |
egress 容器 (仅此容器有 NET_ADMIN + /dev/net/tun)
    nft inet iso_killswitch  policy drop
    无 eth0 默认路由；仅 TROJAN_IP/32
    IPv6 关闭；resolv.conf = 127.0.0.1（sing-box 监听 :53）；丢掉 127.0.0.11
    sing-box TUN tun0 + default via tun0（default_interface=eth0，禁止 auto_detect）
    Trojan outbound：TLS verify + SNI，server 为启动时解析的 IPv4
    |
chromium 容器  network_mode: service:egress
    无 NET_ADMIN / 无 host 网络 / 无 docker.sock
    /config 独立 volume（Cookie、下载）
    WEB 关闭；VNC 在共享 netns 的 5900
```

浏览器 **不** 需要 `NET_ADMIN`。egress 的 capability 只为 TUN/路由/nft。`privileged: false`，不挂 docker socket，不用 host 网络。

代理进程退出时 entrypoint **不会** 把默认路由加回去，而是留在 drop 状态并重启 sing-box。这才是 kill-switch；`network_mode: service:egress` 只是让 Chromium 没有第二条网卡。

实测：删掉 Docker 默认路由后，sing-box 1.14.4 即使配置了 `default_interface` 仍报 `missing default interface`，`auto_route` **不会** 安装 tun 默认路由。overlay 在 `tun0` 出现后执行 `ip route replace default dev tun0`。健康检查要求这条 tun 默认路由存在。

---

## 流程 A（推荐）：单身份先跑通

宿主机必须先通过 `./scripts/iso-preflight.sh`（`iso-up.sh` 会调用）。**CentOS 7 / kernel 3.10 / 无 Docker / 约 1 GiB RAM 是部署阻断**，见 `HOST.md`。不要在 EL7 上装不受支持的 Docker 来绕过。

在美国 Linux 服务器上，cwd 为本仓库里的 `isolation/`。

```bash
cd isolation
cp identities/identity-a.env.example identities/identity-a.env
# 编辑 identities/identity-a.env：填入真实 Trojan 主机/端口/密码/SNI、VNC 口令
# 不要把 TROJAN_INSECURE 设为 true
mkdir -p data/identity-a
./scripts/iso-up.sh identities/identity-a.env
./scripts/iso-status.sh identities/identity-a.env
```

本机（笔记本）连桌面：

```bash
./scripts/iso-vnc-tunnel.sh identities/identity-a.env USER@US_LINUX_SERVER
# 另开终端：VNC 客户端连接 127.0.0.1:5901
```

独立停止（先给 Chromium SIGTERM，等待配置目录落盘，再停 egress；**保留** volume）：

```bash
./scripts/iso-down.sh identities/identity-a.env
# 重启同一身份：
./scripts/iso-restart.sh identities/identity-a.env
```

Web GUI 已关（`WEB_LISTENING_PORT=-1`）。不要把 `5901` 改成 `0.0.0.0:5901`。

---

## 流程 B：多身份并行（必须是不同的真实出口）

```bash
cp identities/identity-b.env.example identities/identity-b.env
# identity-b 必须使用与 A 不同的 TROJAN_SERVER:TROJAN_PORT（以及不同 HOST_VNC_PORT、ISO_DATA_DIR）
./scripts/validate-exits.sh
./scripts/iso-up.sh identities/identity-a.env
./scripts/iso-up.sh identities/identity-b.env
```

`validate-exits.sh` 会拒绝：同一 `TROJAN_SERVER:TROJAN_PORT` 元组、同一 `TROJAN_PUBLIC_EXIT_CLAIM`、同一 `ISO_IDENTITY`、同一宿主机 VNC 端口、占位密码、文档用域名、`TROJAN_INSECURE`。

**不同 host:port 不是不同公网 IP 的证明。** 两个 Trojan 端点可以落到同一出口 NAT/anycast。脚本不解析、不探测 live IP。只有你自己确认出口不同时，才填写不同的 `TROJAN_PUBLIC_EXIT_CLAIM`。

每个身份：

- 独立 Compose 项目，可单独 up/down
- 独立 `data/<id>/` → 容器 `/config`（Cookie、书签、下载）
- 独立 loopback VNC 端口（示例：A=5901，B=5902）
- 独立 Trojan 上游；**不要** 指望「两个浏览器容器」自动变成两个 IP

---

## 安全与网络细节

- Chromium 策略叠加 `chromium/isolation-policies.json`：`WebRtcIPHandling=disable_non_proxied_udp`，并加启动参数 `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`。这只是应用层补充；UDP 仍由 kill-switch 丢掉或走 TUN。
- 优雅退出：`iso-down.sh` 向 `/usr/bin/chromium-browser` 发 SIGTERM，最多等 20s，再 `compose stop`（chromium 30s / egress 10s）。`KEEP_APP_RUNNING=0`，避免 s6 在关机过程中把浏览器拉起来。
- 健康检查（egress）：nft 表存在、IPv4 默认路由不得指向非 tun0、**必须有 default via tun0**、无 IPv6 默认路由、`resolv.conf` 为 `127.0.0.1` 且不含 `127.0.0.11`、`sing-box` 在跑、`tun0` 存在。进程在但没有 tun 默认路由视为不健康。代理挂了会变 unhealthy，但 **不会** 因此恢复直连。
- 证书：生产配置写死 `insecure: false`。自签证书请用 `TROJAN_CERTIFICATE_PATH` 提供 CA，而不是关校验。
- 镜像：`ghcr.io/sagernet/sing-box:v1.14.4@sha256:0788ffbddab2c68a99a2dd4780bbc50902f159af6f589df3ee74a8389d278279`。`jlesage/chromium:v26.10.1` **未**钉 digest（未在本环境拉取该镜像）。
- 密码：走 service `env_file` 字面值，避免 compose 把 `$` 当变量展开。`iso-up` 写入 `data/<id>/.compose.env`（mode 600）。`docker inspect` 仍能看到容器环境里的口令（Chromium 也挂了同一 env_file，因此浏览器进程环境里有 Trojan 口令）。
- `/dev/net/tun` 是 TUN 设备节点，不是 docker.sock，也不是 host 网络。
- `ENABLE_CJK_FONT=1` 会在 Chromium 启动时经 TUN 访问 Alpine 仓库；没有可用 Trojan 时字体安装会失败，不应变成直连。

---

## 环境依赖（不要默认已经装齐）

| 用途 | 依赖 | 缺了会怎样 |
| --- | --- | --- |
| `test-syntax.sh` | `bash`, `python3`（**只要标准库，不要 PyYAML**）, `jq`（生成配置） | 上一轮本地静态测试在缺 PyYAML 时直接失败；现已改为 stdlib |
| compose 插值回归 | `docker compose` v2 | 跳过密码 `$` 测试 |
| netns 隔离 | `sudo -n`, `iproute2`, `nftables` | 跳过 netns 段 |
| Docker 隔离 | Docker 引擎、`/dev/net/tun`、能拉 `ghcr.io/sagernet/sing-box` | 跳过 docker 段 |
| 真实桌面 | 再加 `jlesage/chromium:v26.10.1`、可用 Trojan | **本仓库测试不跑这一段** |
| 目标机部署 | 内核 ≥ 4.18、非 EL7、Docker Compose v2、`/dev/net/tun`、MemTotal ≥ 2048 MiB | `iso-preflight.sh` 失败即停；**不会** 在 CentOS 7 上装 Docker |

```bash
cd isolation
./tests/test-syntax.sh
./tests/test-isolation.sh
```

GitHub Actions：`.github/workflows/isolation-overlay.yml`（只跑 overlay，不构建上游 Chromium 镜像）。

**已测的是 kill-switch 原语**（无 eth0 默认路由、nft drop、127.0.0.11、IPv6、UDP 无直路、进程死后不恢复默认路由、tun default、127.0.0.1:53 监听）。**不是** 端到端浏览器流量，也 **不是** 真实 Trojan 故障切换。proxy-down / 黑洞节点不能代替 live failover。

---

## 未验证（必须当未知）

本次 **没有** 连用户的 Trojan、**没有** 在用户服务器部署、**没有** 打开 Gmail/Yahoo/Claude、**没有** 测量任何公网出口 IP、**没有** 启动 jlesage/chromium。

- 某身份「现在的公网 IP」：**未验证**
- 两个 Trojan 端点是否同一公网出口：**未验证**（配置层只能管 tuple/claim）
- 登录态、Cookie、WebRTC 在真实页面上的行为：**未验证**
- SSH 隧道打到用户机器：**未验证**（只验证了 compose 把 5900 发到宿主机 `127.0.0.1`）
- Chromium `USER_ID` 对 `/config` 的 chown 是否在目标机成功：**未验证**（jlesage 入口以 root 启动并保留 CHOWN；未拉浏览器镜像）
- egress 重启时 Docker 对 `network_mode: service:egress` 的命名空间拆掉/重建：**未做 compose 级 teardown 测试**
- 用户 CentOS 7 目标机（kernel 3.10、无 Docker、无 nft、985 MiB RAM）：**判定为部署阻断**（见 `HOST.md`）。未在该机安装或启动任何容器。
- 单身份 Chromium 实际 RSS：**未测**（preflight 只拒绝小于 2 GiB 的尝试；4 GiB 也不是已验证够用）

---

## 目录

```
isolation/
  compose.yaml
  identities/*.env.example
  egress/          # sing-box + kill-switch 镜像
  chromium/        # 额外 managed policy
  HOST.md          # 最低宿主机；CentOS 7 为阻断
  scripts/         # iso-preflight/up/down/restart/status/vnc-tunnel/validate-exits
  tests/
  data/            # 本地数据（gitignored）
```
