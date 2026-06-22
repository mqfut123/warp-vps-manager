# WARP VPS Manager

一键把命中 Google 官方 IP 快照的 Google、YouTube、Gemini 相关出站流量切到 Cloudflare WARP，普通网站继续直连。

这个项目面向空 VPS、代理落地机、客户自助环境。你不需要改 Xray、sing-box、Hysteria、3x-ui 配置，也不需要给每个业务单独写分流规则。脚本安装时会自动检查环境，并让你选择 Socks5 稳定模式或 WireGuard 高级模式。

## 解决什么问题

- VPS 原生 IP 访问 Google Search、Gemini、Play、YouTube Premium 体验不稳定。
- 客户机器上已经跑了 Xray / sing-box / Hysteria，不想让安装脚本改业务配置。
- 不想走全局 WARP，只希望 Google 默认服务相关流量走 WARP。
- 不想靠手写十几条老 Google IP 段赌覆盖率。
- WARP、redsocks 或规则异常时，需要明确报错并尝试恢复本机链路。

## 一键安装

```bash
sudo bash -c 'set -e; if ! command -v curl >/dev/null 2>&1; then if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl ca-certificates; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates; elif command -v yum >/dev/null 2>&1; then yum install -y curl ca-certificates; else echo "找不到 curl，也找不到 apt/dnf/yum，无法自举安装" >&2; exit 1; fi; fi; t="$(mktemp)"; curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh -o "$t"; bash "$t"'
```

这条 bootstrap 命令会在缺少 `curl` 时先尝试用 `apt`、`dnf` 或 `yum` 安装 `curl` 和证书。若脚本下载失败，命令会直接非零退出，不会假装安装成功。

安装前脚本会先检查可用内存。如果可用内存低于 1G 且没有 Swap，会提示你创建 Swap 或自行承担安装失败风险。

在弹出模式选择前，脚本会先检测当前 VPS 原生 IPv4 出口的 Gemini 和 YouTube Premium 解锁状态，安装完成后会再用 WARP 分流后的 IPv4 出口显式检测一次。

随后脚本会让你选择模式。普通用户直接回车默认使用 Socks5 稳定模式；明确需要 UDP/QUIC 也走 WARP 时再选择 WireGuard 高级模式：

- **Socks5 稳定模式**：使用 Cloudflare 官方 WARP 客户端本地 SOCKS + `redsocks` + `nftables`，命中规则的 Google IPv4 TCP 走 WARP；UDP/443 会被阻断，通常会促使浏览器回落 TCP，少数不支持回落的客户端可能失败。
- **WireGuard 高级模式**：使用固定版本 `wgcf` 生成 WARP WireGuard 配置，只把 Google CIDR 路由到 WARP 网卡，TCP+UDP 都可走 WARP，但需要 TUN/WireGuard 内核能力，路由风险更高。

选择 Socks5 模式时会询问 WARP SOCKS 端口。直接回车会随机选择一个未被占用的高位端口，安装完成后会显示实际端口。

建议准备至少 1GB 可用磁盘空间。Ubuntu/Debian 上的 `cloudflare-warp` 官方包会拉取较多图形/桌面相关依赖，这是 Cloudflare 官方包依赖链导致的，不是本脚本额外启用 GUI。

CentOS/RHEL/Rocky/AlmaLinux 的部分软件源没有 `redsocks` 包。脚本会先尝试包管理器安装；如果没有可用包，会从 `darkk/redsocks` 固定 commit 源码构建，并校验源码包 SHA256。

使用 fork 或自定义 raw 地址：

```bash
WARP_VPS_REPO_BASE="https://raw.githubusercontent.com/YOUR_NAME/warp-vps-manager/main" \
sudo -E bash -c 'set -e; if ! command -v curl >/dev/null 2>&1; then if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl ca-certificates; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates; elif command -v yum >/dev/null 2>&1; then yum install -y curl ca-certificates; else echo "找不到 curl，也找不到 apt/dnf/yum，无法自举安装" >&2; exit 1; fi; fi; t="$(mktemp)"; curl -fsSL "$WARP_VPS_REPO_BASE/install.sh" -o "$t"; bash "$t"'
```

## 核心特性

- root 一键安装，缺依赖自动补齐，失败时直接中止。
- 安装时自动检查内存、Swap、TUN 和内核能力，并给出模式推荐。
- Socks5 稳定模式使用 Cloudflare 官方 WARP 客户端 SOCKS，不接管全局默认路由。
- WireGuard 高级模式使用固定版本 `wgcf` 生成标准 WireGuard 配置，只给 Google CIDR 加路由。
- 命中规则的 Google / YouTube / Gemini 相关出站流量走 WARP。
- 普通网站、普通客户业务、Google Cloud 客户外部 IP 默认直连。
- Socks5 模式下 Google/YouTube UDP/443 默认阻断，通常促使 QUIC 回落 TCP，避免常见浏览器绕过 WARP。
- Socks5 模式下 Google 目标 IPv6 默认阻断，避免 IPv6 泄漏。
- WireGuard 模式下命中 Google CIDR 的 TCP/UDP 都走 WARP。
- 规则快照固定在本仓库，用户机器不会后台自动抓取 Google 规则。
- `warp-vps update` 同步脚本和固定规则快照；更新后自检失败会恢复旧版本。
- `warp-vps status` 和 `warp-vps test` 使用中文彩色自检输出，小白也能直接看懂是否正常。
- 安装前和安装后都会检测 Gemini、YouTube Premium 的 IPv4 出口结果，并明确显示“可用 / 不可用 / 无法确认”。
- 健康检查定时器会定期检测 WARP SOCKS、redsocks、nftables 和 Google 规则命中，链路异常时做有界恢复。
- 卸载时移动到时间戳备份目录，不永久删除安装文件。

## 和其他方案有什么不同

| 方案 | 适合场景 | 分流方式 | IP 规则 | 主要区别 |
|---|---|---|---|---|
| 本项目 Socks5 模式 | VPS 上稳定分流 Google 默认服务相关流量 | 系统 `OUTPUT` 透明 TCP 分流 | Google 官方 `goog.json - cloud.json` 固定快照 | 架构接近 `warp-google-unlock`，但规则更系统，使用 nftables、随机端口、IPv6/UDP 边界、自检、更新和安全卸载 |
| 本项目 WireGuard 模式 | 需要 Google/YouTube UDP 也走 WARP | WireGuard 网卡 + Google CIDR 路由 | Google 官方 `goog.json - cloud.json` 固定快照 | TCP+UDP 都可走 WARP，但需要 TUN/WireGuard 能力 |
| `vps8899/warp-google-unlock` | 快速修复 Google/Gemini 访问 | 系统级 iptables + redsocks | 手写经典 Google 段和若干大网段 | 简单直接，但部分 `34/35` 大段可能把 Google Cloud 客户资源也带进 WARP |
| `yonggekkk/warp-yg` | WARP 多功能工具箱、wgcf/warp-go、全局或多模式玩法 | WireGuard/WARP 多模式 | 侧重 WARP 接入和解锁检测 | 功能丰富，但不是专门为“Google consumer IP 级透明分流且不改业务代理配置”收敛设计 |
| Xray/sing-box 域名分流 | 你愿意维护代理核心配置 | 应用层域名/geosite 分流 | geosite / geodata | 域名语义更强，但需要改现有代理配置，无法覆盖所有系统出站进程 |
| WARP 全局模式 | 整台机器都想走 WARP | 默认路由或 WireGuard 全局接管 | 不需要目标规则 | 简单，但会影响所有业务流量，不适合落地机客户环境 |

本项目的取舍很明确：不追求大而全，只做空 VPS 上可复制、可排障、可更新的 Google 默认服务系统级 IP 分流。普通用户优先选 Socks5；明确需要 UDP/QUIC 的用户再选 WireGuard。

## IP 规则来源

规则来自 Google 官方发布的两个文件：

- `https://www.gstatic.com/ipranges/goog.json`
- `https://www.gstatic.com/ipranges/cloud.json`

生成方式：

```text
Google 默认域名公网 CIDR 快照 = goog.json - cloud.json
```

这和 Google 官方文档建议一致：从 Google-owned 全量公网段中减去 Google Cloud 客户资源外部 IP，得到 Google APIs 和 Google services default domains 使用的净范围。它是 IP 近似分流，不是域名识别，也不是 YouTube/Gemini 专属服务清单。

当前快照：

```text
goog/cloud creationTime: 2026-06-21T19:03:53.490008
generated_at: 2026-06-22T03:47:54.626495+00:00
IPv4: 261
IPv6: 84
```

边界也要说清楚：这是 IP/CIDR 系统级分流，不是域名级分流。Google 会动态调整 IP，维护者需要定期重新生成规则并提交，用户通过 `warp-vps update` 获取新快照。`warp-vps test/status` 会同时显示本机链路、规则命中、Gemini 和 YouTube Premium 检测结果；其中服务解锁检测基于公开网页特征和本机 IPv4 出口，Google 页面或地区策略变化时可能显示“无法确认”。服务解锁结果是信息项，不参与安装、更新、重启命令的退出码判断。

## 支持系统

优先支持：

- Debian 12
- Debian 13
- Ubuntu 22.04 LTS / 24.04 LTS
- CentOS 8 / 9
- RHEL 8 / 9
- Rocky Linux 8 / 9
- AlmaLinux 8 / 9

CentOS 7 不支持。CentOS/Rocky/AlmaLinux 9 会按 RHEL 兼容路径尝试安装；Socks5 模式需要 Cloudflare 官方 RPM 仓库可用。若系统仓库缺少 `redsocks`，安装器会用固定源码包构建；源码下载或校验失败会直接中止。WireGuard 模式不依赖官方 `cloudflare-warp` 包，但需要 TUN/WireGuard 内核能力。

如果 VPS 或容器内核缺少 `nftables` NAT 能力，安装会 fail-fast。

## 管理命令

```bash
warp-vps status
warp-vps test
warp-vps restart
warp-vps update
warp-vps logs
warp-vps uninstall
```

常用判断：

- `warp-vps status`：显示当前配置、规则快照和中文彩色状态自检。
- `warp-vps test`：只运行中文彩色状态自检。
- `warp-vps restart`：重启本地 WARP 分流链路并重新加载规则。
- `warp-vps update`：从配置的 GitHub raw 地址拉取最新脚本和固定规则快照，失败时回滚到旧版本。
- `warp-vps uninstall`：停止服务并把安装文件移动到备份目录，系统包保留；如果安装时创建过 `/swapfile-warp-vps-manager`，会停用并移动到备份目录。

## 重要边界

- 默认不做全局 WARP。
- 不修改 Xray、sing-box、Hysteria、3x-ui 等业务配置。
- 不做域名级 DNS 分流。
- Socks5 模式不承诺透明代理 UDP，UDP/443 通过阻断促使多数浏览器回落 TCP；不支持回落的应用可能失败。
- WireGuard 模式会增加 WARP 网卡和 Google CIDR 路由，可能和已有 WireGuard/TUN 类服务冲突。
- WireGuard 模式使用第三方开源 `wgcf` 获取 WARP WireGuard 配置，不使用 Cloudflare 官方客户端；脚本固定下载 `wgcf v2.2.31` 并校验 SHA256，不跟随 latest 自动漂移。
- RPM 系统缺少 `redsocks` 包时，脚本会从 `darkk/redsocks` 固定 commit 构建 `redsocks 0.5` 并校验源码 SHA256。
- 不后台自动抓取 Google 实时规则。
- 不永久删除安装文件。
- 一键安装和 `warp-vps update` 信任配置的 GitHub raw 地址。生产发布前应保护 GitHub 账号、分支和 release 流程。

## 更新规则快照

维护者手动更新固定规则：

```bash
python3 scripts/generate-google-rules.py --output rules
```

检查 diff 后提交到 GitHub。用户侧通过下面命令获取新快照：

```bash
warp-vps update
```

## 发布前检查

发布前至少执行：

```bash
bash -n install.sh
bash -n bin/warp-vps
python3 - <<'PY'
import ipaddress, json
from pathlib import Path
meta = json.loads(Path("rules/rules.meta.json").read_text())
for name, expected in [("google_ipv4.txt", meta["ipv4_count"]), ("google_ipv6.txt", meta["ipv6_count"])]:
    lines = [line.strip() for line in Path("rules", name).read_text().splitlines() if line.strip()]
    assert len(lines) == expected
    for line in lines:
        ipaddress.ip_network(line)
print("规则检查通过")
PY
```

最终发布前还应在干净 Debian/Ubuntu/CentOS/RHEL/Rocky/AlmaLinux VPS 上做真实安装测试。

## 参考项目

本项目受到以下项目启发并参考了部分思路：

- https://github.com/vps8899/warp-google-unlock
- https://github.com/yonggekkk/warp-yg
- https://github.com/lmc999/RegionRestrictionCheck
- https://github.com/ViRb3/wgcf

相关官方文档：

- https://developers.cloudflare.com/warp-client/get-started/linux/
- https://developers.cloudflare.com/warp-client/get-started/
- https://knowledge.workspace.google.com/admin/security/obtain-google-ip-address-ranges
- https://docs.cloud.google.com/appengine/docs/standard/outbound-ip-addresses
