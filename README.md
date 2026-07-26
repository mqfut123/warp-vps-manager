# WARP VPS Manager

**精准分流 Google 流量，一条命令接入 Cloudflare WARP。**

[![CI](https://github.com/mqfut123/warp-vps-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/mqfut123/warp-vps-manager/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mqfut123/warp-vps-manager)](https://github.com/mqfut123/warp-vps-manager/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 一键安装

使用 `root` 用户运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh)
```

全新安装默认选择 **WireGuard + 1G Swap**。检测到已有项目安装时，再运行同一命令会进入全局管理菜单。

## 和其他方案对比

WARP VPS Manager 的核心优势是规则精度：使用 Google 官方公网 IP 列表，并排除 Google Cloud 客户地址，只把目标 Google 流量交给 WARP。

| 方案 | 分流范围 | 更适合 |
|---|---|---|
| **WARP VPS Manager** | `goog.json - cloud.json`，同时覆盖 IPv4 与 IPv6 | 只改善 Google 访问，并保留网站、面板和其他业务的 VPS 原生出口 |
| [warp-google-unlock](https://github.com/vps8899/warp-google-unlock) | 内置 `34.0.0.0/9` 等固定大网段，规则更宽 | 希望用固定规则快速部署 Google 透明代理 |
| [warp-yg](https://github.com/yonggekkk/warp-yg) | 全局 WARP 与多种 WARP 管理能力 | 需要 wgcf、warp-go、WARP+、团队账户或对端优选等完整工具箱 |
| Xray / sing-box 分流 | 可按域名配置，只覆盖进入代理程序的流量 | 已有完整代理链路并愿意自行维护规则 |
| 全局 WARP | 整台 VPS 的流量统一更换出口 | 所有业务都需要使用 WARP |

## 为 Google 访问而设计

- **保留原生出口**：网站、面板、API 和其他业务继续使用 VPS 原生 IP。
- **不改代理配置**：在系统出站层完成分流，无需修改 Xray、sing-box、Hysteria 或 3x-ui。
- **两种运行模式**：WireGuard 完整承载双栈与 UDP；Socks5 适合更轻量的 TCP 透明代理。
- **自带管理工具**：状态、诊断、解锁检测、更新、切换模式、日志和卸载统一由 `warp-vps` 管理。

适合 VPS 原生 IP 无法正常使用 Gemini、Google Search 或 YouTube Premium，同时又需要保留其他业务原生出口的场景。

## 选择运行模式

| 模式 | 分流效果 | 推荐场景 |
|---|---|---|
| **WireGuard** | 命中规则的 Google IPv4、IPv6、TCP、UDP 和 QUIC 全部走 WARP | 默认选择；需要完整协议与双栈支持 |
| **Socks5** | Google IPv4 TCP 走 WARP；Google IPv4 UDP/443（QUIC）与 Google IPv6 拒绝 | 只需要 TCP，或希望减少对现有路由的改动 |

Socks5 会让支持回落的客户端从 QUIC 改用经 WARP 转发的 TCP；其他 Google IPv4 UDP 端口和非 Google 目标 UDP 不受影响。

## 支持环境

- 使用 `systemd` 的 Linux VPS
- Debian、Ubuntu 及其他 APT 系统
- Fedora、CentOS、RHEL、Rocky Linux、AlmaLinux 及其他 DNF/YUM 系统
- WireGuard 模式需要系统能够通过 `wg-quick` 创建项目网卡
- Socks5 模式需要 nftables `OUTPUT` NAT，并且系统与架构有可用的 Cloudflare WARP 软件包

安装器按系统实际提供的包管理器和网络能力选择安装路径，不依赖固定发行版版本表。

## 管理命令

直接运行 `warp-vps` 或 `warp-vps menu` 打开交互式管理菜单。

| 命令 | 用途 |
|---|---|
| `warp-vps status` | 查看服务、接口、端口和分流规则 |
| `warp-vps test` | 运行分流与外部连通性诊断 |
| `warp-vps unlock-check` | 检测 Gemini 和 YouTube Premium |
| `warp-vps restart` | 重启 WARP 分流链路 |
| `warp-vps update` | 更新程序与 Google IP 规则 |
| `warp-vps switch wireguard` | 切换到 WireGuard |
| `warp-vps switch socks --socks-port auto` | 切换到 Socks5 并自动选择端口 |
| `warp-vps logs` | 查看最近的服务日志 |

进入“重装或切换模式”后，直接回车保持当前模式；输入 `2` 可从 Socks5 切换到 WireGuard，输入 `1` 可从 WireGuard 切换到 Socks5。

## 卸载

| 命令 | 用途 |
|---|---|
| `warp-vps uninstall` | 交互卸载，并选择是否卸载运行依赖 |
| `warp-vps uninstall --yes` | 非交互卸载项目，保留依赖 |
| `warp-vps uninstall all` | 非交互卸载项目及 Cloudflare WARP、redsocks、wireguard-tools |

三种卸载方式都会先停止自动修复，并确认分流规则已经失效，再把项目文件移到 `/var/backups/warp-vps-manager/`。

## IP 规则来源

规则来自 Google 官方的 [公网 IP 列表](https://www.gstatic.com/ipranges/goog.json)，并排除 [Google Cloud 客户外部 IP](https://www.gstatic.com/ipranges/cloud.json)。运行 `warp-vps update` 即可获取项目发布的最新规则。

本项目使用 [MIT License](LICENSE)。
