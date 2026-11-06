# 宿主机兼容性（失败即停）

本 overlay **不会** 为了装进老机器而改成 iptables-legacy、关掉 TLS、或降低 nft kill-switch。
`scripts/iso-preflight.sh` 在 `iso-up.sh` 之前执行；不通过就拒绝启动。

## 最低允许启动的宿主机（preflight 硬门槛）

必须同时满足：

| 项 | 门槛 | 依据 |
| --- | --- | --- |
| 发行版 | 非 RHEL/CentOS/OL **7** | CentOS Linux 7 已于 2024-06-30 EOL |
| 内核 | **≥ 4.18**（推荐 5.15+ / 6.x） | Docker 已去掉对 kernel &lt; 4.0 / fuse-overlayfs &lt; 4.18 的 EL7 特例（moby#49184、#48208）。nftables 主线自 3.13；EL7 的 3.10 是回移植，Alpine 容器里的现代 `nft` 用户态 **未验证** |
| Docker | Engine + **Compose v2**（`docker compose`）已安装且 daemon 可用 | 现行 `docker-ce.spec` 仍 `Requires: nftables`，打包目标是 RHEL 8/9/10、CentOS Stream 9/10、Fedora，**不再构建 CentOS 7**（docker-ce-packaging `88a6cdc`，v27.0 起） |
| TUN | 宿主机存在 `/dev/net/tun` | egress 需要 TUN；**有 TUN ≠ 可以跑 overlay** |
| CPU | 原生 **linux/amd64 或 linux/arm64** | `jlesage/chromium:v26.10.1` 与 `sing-box:v1.14.4` 官方 index 均含 arm64。禁止 qemu/amd64 模拟 |
| 内存 | `MemTotal` **≥ 2048 MiB** 才允许尝试 | 见下文；**不是** 已测够用值 |
| kill-switch | 容器内 `nft` + 内核 `nf_tables` | 不用宿主机 `iptables` 1.4.x 当 kill-switch |

推荐（仍不保证 Chromium 桌面内存够用）：**Ubuntu 22.04/24.04 LTS、Debian 12、RHEL 9 / Rocky 9**，内核 5.15+，**4 GiB+ RAM**，已装 Docker CE 24+ 与 Compose v2，宿主机 `nft` 可用，cgroup v2 更好（v1 不是本 overlay 的独立阻断）。

本 overlay **在 Ubuntu 24.04 + kernel 6.12 + Docker 29 + nftables v1.0.9 + 16 GiB RAM 的评测环境** 跑过 kill-switch 原语。那不是用户的 CentOS 7 机器。

## 明确拒绝的「凑合安装」

- 在 CentOS 7 上用 `get.docker.com`、老 `docker-ce-20.10`、或第三方 kernel 把 Docker 塞进去：现行 Docker 不再为 EL7 出包，且用户已排除 **重装系统 / 换内核 / 大范围改防火墙**。
- 把 kill-switch 改写成宿主机 `iptables`/`ip6tables` 1.4.21：没有 `inet` 表、v4/v6 会分叉、和 Docker/firewalld 规则交织，属于削弱隔离。
- 为了老内核关掉 `tls.insecure=false`、`strict_route`、或 nft `policy drop`。

有 `/dev/net/tun`、有 iptables 1.4.21、有 swap，**不足以** 声明可以部署。

## 用户授权只读预检中的真实目标机（部署阻断）

预检值（本 overlay **没有** SSH 到该机；数字来自授权只读预检，原样记录）：

| 项 | 值 |
| --- | --- |
| OS / 内核 | CentOS 7，`3.10.0-1160.114.2.el7.x86_64` |
| CPU / RAM / swap | 2 vCPU，**985 MiB RAM**，8 GiB swap |
| 磁盘 | 约 33 GiB 空闲（容量本身不是阻断） |
| Docker / Compose | **未安装** |
| nft | **无** |
| iptables | 1.4.21（legacy） |
| `/dev/net/tun` | 存在 |
| 约束 | 授权部署，**禁止** 重装 OS / 换内核 / 大范围改防火墙 |

对照上表：**不能安全部署本 overlay。** 不是「缺一个 yum 包」。缺的是被支持的内核、被支持的 Docker、nftables kill-switch 路径，以及单身份 Chromium 桌面所需的内存余量。

sing-box **v1.14.4** 跑在 Alpine 容器里，不跑在 CentOS 用户态；它仍然使用**宿主机内核**的 TUN / netfilter / 路由。官方镜像 `ghcr.io/sagernet/sing-box:v1.14.4@sha256:0788ffbddab2c68a99a2dd4780bbc50902f159af6f589df3ee74a8389d278279`。`auto_redirect` 已关闭（避免和独立 nft 表打架）；kill-switch 仍要内核理解容器内 `nft` 下发的 `table inet`。这在 3.10+EL7 回移植上 **未测**，因此直接拒绝，而不是赌一次。

cgroup：CentOS 7 是 cgroup v1。旧 Docker 能用 v1；现行 Docker/containerd 打包已不面向 EL7。cgroup 不是唯一阻断，内核 + 无 Docker + EOL 已经足够。

## 内存：单身份也不确定

985 MiB + 8 GiB swap **没有**在本 overlay 上跑过 `jlesage/chromium:v26.10.1`。下面不是测量值：

- 镜像本身约 400 MB 压缩 / 展开后更大；再加 Docker daemon、egress（sing-box）、一个 Chromium 渲染进程。
- compose 里 `shm_size: "2gb"` 来自常见 Chromium 容器习惯；jlesage 另有 `--disable-dev-shm-usage`。即使缩小 shm，也救不了 EL7。
- swap 可能让进程「活着」但会严重抖动，**不能**当成可用桌面。

preflight：`< 2048 MiB` 拒绝尝试；`< 4096 MiB` 警告。**4 GiB 也未经本 overlay 实测。** 真实下限未知。

## 真实 Trojan 节点

用户给 parent executor 的测试节点 **没有** 转发到本评测环境。本仓库测试仍只用黑洞/`192.0.2.0/24` 夹具。不要把配置检查当成该节点的 live 连通证明。
