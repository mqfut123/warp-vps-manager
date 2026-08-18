# WARP VPS Manager

**默认精准分流 Google，也可让整台 VPS 全局接入 Cloudflare WARP。**

[![CI](https://github.com/mqfut123/warp-vps-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/mqfut123/warp-vps-manager/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mqfut123/warp-vps-manager)](https://github.com/mqfut123/warp-vps-manager/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 一键安装

使用 `root` 用户运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh)
```

全新交互安装默认选择 **Google 精准分流 + 1G Swap**。安装器先处理 Swap，再选择 Google 精准分流或全局 WARP，最后根据出站 UDP 探测结果建议 WireGuard 或 Socks5。检测到已有项目安装时，再运行同一命令会进入管理菜单。

非交互安装、重装或切换省略 `--swap` 时会尝试创建 1G Swap；磁盘空间不足，或创建失败且已确认清理完成时，会警告并继续安装。无法确认清理完成时仍停止。显式使用 `--swap auto` 或 `--swap N` 时保持严格语义，创建条件不满足会停止安装；`--swap none` 明确跳过。

## 和其他方案对比

WARP VPS Manager 默认使用 Google 官方公网 IP 列表，并排除 Google Cloud 客户地址，只把目标 Google 流量交给 WARP；需要统一出口时，可在同一安装流程切换为全局 WARP。

| 方案 | 分流范围 | 更适合 |
|---|---|---|
| **WARP VPS Manager** | 默认 `goog.json - cloud.json` 精准分流，可选全局 WARP | 既要精准改善 Google，也希望按需统一整台 VPS 出口 |
| [warp-google-unlock](https://github.com/vps8899/warp-google-unlock) | 内置 `34.0.0.0/9` 等固定大网段，规则更宽 | 希望用固定规则快速部署 Google 透明代理 |
| [warp-yg](https://github.com/yonggekkk/warp-yg) | 全局 WARP 与多种 WARP 管理能力 | 需要 wgcf、warp-go、WARP+、团队账户或对端优选等完整工具箱 |
| Xray / sing-box 分流 | 可按域名配置，只覆盖进入代理程序的流量 | 已有完整代理链路并愿意自行维护规则 |
| 全局 WARP | 整台 VPS 的流量统一更换出口 | 所有业务都需要使用 WARP |

## 两种路由范围

Google 精准分流和全局 WARP 都可以搭配 WireGuard 或 Socks5，切换路由范围不需要重新选择另一套管理工具。

- **精准分流 Google（默认）**：网站、面板、API 和其他业务继续使用 VPS 原生 IP。
- **全局走 WARP**：WireGuard 接管公网 IPv4、IPv6 与全部协议；Socks5 接管 VPS 主动发起的公网 IPv4 TCP。
- **不改代理配置**：在系统出站层完成分流，无需修改 Xray、sing-box、Hysteria 或 3x-ui。
- **两种运行模式**：WireGuard 完整承载双栈与 UDP；Socks5 适合更轻量的 TCP 透明代理。
- **自带管理工具**：状态、诊断、解锁检测、更新、切换模式、日志和卸载统一由 `warp-vps` 管理。

WireGuard 全局模式让未绑定原生源地址的公网 IPv4、IPv6、TCP、UDP 和 QUIC 全部走 WARP；现有及新入站连接回包、显式绑定 VPS 原生源地址的流量和局域网路由保留原生路径。Socks5 不承载 UDP 或 IPv6；其全局模式接管 VPS 主动发起的公网 IPv4 TCP，入站连接回包保持原生路径，并继续拒绝 Google IPv4 UDP/443（QUIC）和 Google IPv6；其他非 Google UDP 与 IPv6 仍使用 VPS 原生出口。

## 选择运行模式

| 模式 | Google 精准分流 | 全局走 WARP |
|---|---|---|
| **WireGuard** | Google IPv4、IPv6、TCP、UDP 和 QUIC | 公网 IPv4、IPv6 与全部协议 |
| **Socks5** | Google IPv4 TCP；Google IPv4 UDP/443（QUIC）与 Google IPv6 拒绝 | VPS 主动发起的公网 IPv4 TCP；Google IPv4 UDP/443（QUIC）与 Google IPv6 继续拒绝 |

Socks5 会让支持回落的客户端从 QUIC 改用经 WARP 转发的 TCP；其他 Google IPv4 UDP 端口和非 Google 目标 UDP 不受影响。

全新交互安装会向 Cloudflare STUN UDP/3478 发出有界探测。收到有效回包时，直接回车默认选择 WireGuard；已完成探测但未收到有效回包时，直接回车默认选择 Socks5，并提示 WireGuard 只使用 UDP、不会回退 TCP。检测无法完成时保留 WireGuard 默认；显式输入 `1` 或 `2` 始终按所选模式安装。该探测只用于默认建议；WireGuard 配置生成后，安装器会对域名当前解析出的 WARP 地址依次尝试默认端口 UDP/2408 和 [Cloudflare 公布的 WireGuard 回退端口](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/firewall/#warp-ingress-ip) UDP/500、UDP/1701、UDP/4500，只有 Google IPv4、Google IPv6 均返回、WireGuard 最近握手存在且接收字节增长时才继续安装。更新、开机和显式重启也会重新选择当前可用对端，但不会把解析出的 IP 或运行时端口写死到配置文件。所有对端都失败时会清除本项目路由并提示改用 Socks5。

WARP 对端使用 IPv4 还是 IPv6，只决定 WireGuard 加密包如何到达 Cloudflare，不限制隧道内承载的地址族。底层使用已验证的 IPv4 对端时，Google IPv6 仍通过 WireGuard 的 IPv6 地址和路由走 WARP；只有 Socks5 模式不承载 IPv6。

## 运行条件

- 使用 `systemd` 的 Linux VPS
- 使用 APT、DNF 或 YUM，并能从当前配置的软件源取得所选模式的依赖
- WireGuard 模式需要系统能够通过 `wg-quick` 创建项目网卡并允许出站 UDP；WireGuard 不会回退 TCP；全局范围同时需要 nftables
- Socks5 模式需要 nftables `OUTPUT` NAT，并且系统与架构有可用的 Cloudflare WARP 软件包

安装器按系统实际提供的包管理器和网络能力选择安装路径，不依赖固定发行版版本表。

依赖完整时不会调用包管理器；缺少普通依赖时只提交未安装的软件包，不执行全局 `apt update`，也不主动清理或刷新 DNF/YUM 元数据。首次新增 Cloudflare WARP APT 源时只获取该源的索引；已有源当前没有可用候选时，安装器会提示先由用户运行 `apt update`。已安装但不完整的 Cloudflare WARP 只重装自身，其他已安装组件不会顺带升级。

WireGuard 配置固定使用 `wgcf v2.2.32`，不会动态追随 GitHub `latest`。下载的官方二进制通过对应架构的官方 `checksums.txt` 校验后才会启用。

## 管理命令

直接运行 `warp-vps` 或 `warp-vps menu` 打开交互式管理菜单。

| 命令 | 用途 |
|---|---|
| `warp-vps status` | 查看配置、服务、接口、端口和分流服务运行态 |
| `warp-vps test` | 运行分流与外部连通性诊断 |
| `warp-vps native-unlock-check` | 绕过 WARP 分流，检测原生出口的 Gemini 和 YouTube Premium |
| `warp-vps unlock-check` | 检测当前 WARP IPv4 出口的 Gemini 和 YouTube Premium |
| `warp-vps restart` | 重启 WARP 分流链路 |
| `warp-vps update` | 更新程序与 Google IP 规则；不安装或升级运行依赖，旧版规则差异不会阻止更新 |
| `warp-vps reinstall --scope global` | 保持运行模式并切换到全局 WARP |
| `warp-vps reinstall --scope google` | 保持运行模式并切回 Google 精准分流 |
| `warp-vps switch wireguard` | 切换到 WireGuard |
| `warp-vps switch socks --socks-port auto` | 切换到 Socks5 并自动选择端口 |
| `warp-vps logs` | 查看最近的服务日志 |

进入“重装或切换”后，可重新选择路由范围和 Socks5 / WireGuard 模式；运行模式直接回车保持当前模式。非交互重装未指定 `--scope` 时保留当前范围；全新非交互安装的路由范围默认使用 Google 精准分流，运行模式默认 WireGuard，可用 `--scope` 与 `--mode` 显式指定。

`native-unlock-check` 需要 root 且仅在主动运行时检测：取原生默认接口的第一个 global IPv4，没有 IPv4 时取第一个 global IPv6；通过同一路径显示 Cloudflare Trace 返回的公网 IP 和地区，再复用现有 Gemini、YouTube Premium 判断。它不会暂停服务、修改规则或加入安装后的自动检测；结果只供参考，不影响安装、更新、重启或健康检查。

`unlock-check` 与 `native-unlock-check` 共用相同的页面判定：Gemini 只按首页明确的可用性 marker 判断，同页唯一的三字母地区仅用于展示，不参与可用性结论；marker 缺失或冲突时显示无法确认。YouTube Premium 的地区或页面特征互相冲突时显示无法确认，明确不可用但缺少地区时显示地区未知。

## 卸载

| 命令 | 用途 |
|---|---|
| `warp-vps uninstall` | 交互永久删除项目，并选择是否卸载运行依赖 |
| `warp-vps uninstall --yes` | 非交互永久删除项目，保留依赖 |
| `warp-vps uninstall all` | 非交互永久删除项目及 Cloudflare WARP、redsocks、wireguard-tools |

三种卸载方式都会先停止自动修复，并确认分流规则已经失效，再永久删除确认归属的项目文件，不创建卸载备份。无法确认由本项目创建的现有 WireGuard 配置会保留；若该配置位于项目目录内，卸载会要求先迁移到目录外。

## IP 规则来源

规则来自 Google 官方的 [公网 IP 列表](https://www.gstatic.com/ipranges/goog.json)，并排除 [Google Cloud 客户外部 IP](https://www.gstatic.com/ipranges/cloud.json)。维护者生成并审核固定快照后随项目发布；运行 `warp-vps update` 即可获取已发布的最新规则，不会在 VPS 上直接采用尚未审核的 Google 实时列表。

本项目使用 [MIT License](LICENSE)。
