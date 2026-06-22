# WARP VPS Manager

一键把 Google、YouTube、Gemini 相关出站流量切到 Cloudflare WARP，普通网站继续直连。

这个项目面向空 VPS、代理落地机、客户自助环境。你不需要改 Xray、sing-box、Hysteria、3x-ui 配置，也不需要给每个业务单独写分流规则。脚本会安装 Cloudflare 官方 WARP 客户端，启用本地 SOCKS 模式，再用 `redsocks` + `nftables` 在系统 `OUTPUT` 链做 TCP 透明分流。

## 解决什么问题

- VPS 原生 IP 访问 Google Search、Gemini、Play、YouTube Premium 体验不稳定。
- 客户机器上已经跑了 Xray / sing-box / Hysteria，不想让安装脚本改业务配置。
- 不想走全局 WARP，只希望 Google consumer 服务走 WARP。
- 不想靠手写十几条老 Google IP 段赌覆盖率。
- WARP、redsocks 或规则异常时，需要明确报错并能自动恢复。

## 一键安装

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh)'
```

安装时会询问 WARP SOCKS 端口。直接回车会随机选择一个未被占用的高位端口，安装完成后会显示实际端口。

建议准备至少 1GB 可用磁盘空间。Ubuntu/Debian 上的 `cloudflare-warp` 官方包会拉取较多图形/桌面相关依赖，这是 Cloudflare 官方包依赖链导致的，不是本脚本额外启用 GUI。

使用 fork 或自定义 raw 地址：

```bash
WARP_VPS_REPO_BASE="https://raw.githubusercontent.com/YOUR_NAME/warp-vps-manager/main" \
sudo -E bash -c 'bash <(curl -fsSL "$WARP_VPS_REPO_BASE/install.sh")'
```

## 核心特性

- root 一键安装，缺依赖自动补齐，失败时直接中止。
- 使用 Cloudflare 官方 WARP 客户端 SOCKS 模式，不接管全局默认路由。
- Google / YouTube / Gemini 命中的 TCP 出站流量走 WARP。
- 普通网站、普通客户业务、Google Cloud 客户外部 IP 默认直连。
- Google/YouTube UDP/443 默认阻断，强制 QUIC 回落 TCP，避免绕过 WARP。
- Google 目标 IPv6 默认阻断，避免 IPv6 泄漏。
- 规则快照固定在本仓库，用户机器不会后台自动抓取 Google 规则。
- `warp-vps update` 同步脚本和固定规则快照。
- health timer 定期检测 WARP SOCKS、redsocks、nftables 和 Google 规则命中，异常时做有界恢复。
- 卸载时移动到时间戳备份目录，不永久删除安装文件。

## 和其他方案有什么不同

| 方案 | 适合场景 | 分流方式 | IP 规则 | 主要区别 |
|---|---|---|---|---|
| 本项目 | VPS 上只让 Google consumer 服务走 WARP | 系统 `OUTPUT` 透明 TCP 分流 | Google 官方 `goog.json - cloud.json` 固定快照 | 覆盖更完整，默认排除 Google Cloud 客户 IP，有健康检查和明确失败路径 |
| `vps8899/warp-google-unlock` | 快速修复 Google/Gemini 访问 | 系统级 iptables + redsocks | 手写经典 Google 段和若干大网段 | 简单直接，但部分 `34/35` 大段可能把 Google Cloud 客户资源也带进 WARP |
| `yonggekkk/warp-yg` | WARP 多功能工具箱、wgcf/warp-go、全局或多模式玩法 | WireGuard/WARP 多模式 | 侧重 WARP 接入和解锁检测 | 功能丰富，但不是专门为“Google consumer IP 级透明分流且不改业务代理配置”收敛设计 |
| Xray/sing-box 域名分流 | 你愿意维护代理核心配置 | 应用层域名/geosite 分流 | geosite / geodata | 域名语义更强，但需要改现有代理配置，无法覆盖所有系统出站进程 |
| WARP 全局模式 | 整台机器都想走 WARP | 默认路由或 WireGuard 全局接管 | 不需要目标规则 | 简单，但会影响所有业务流量，不适合落地机客户环境 |

本项目的取舍很明确：不追求大而全，只做空 VPS 上可复制、可排障、可更新的 Google consumer 系统级分流。

## IP 规则来源

规则来自 Google 官方发布的两个文件：

- `https://www.gstatic.com/ipranges/goog.json`
- `https://www.gstatic.com/ipranges/cloud.json`

生成方式：

```text
Google consumer/service CIDR = goog.json - cloud.json
```

这和 Google 官方文档建议一致：从 Google-owned 全量公网段中减去 Google Cloud 客户资源外部 IP，得到 Google APIs 和 Google services default domains 使用的净范围。

当前快照：

```text
goog/cloud creationTime: 2026-06-21T19:03:53.490008
generated_at: 2026-06-22T03:47:54.626495+00:00
IPv4: 261
IPv6: 84
```

边界也要说清楚：这是 IP/CIDR 系统级分流，不是域名级分流。Google 会动态调整 IP，维护者需要定期重新生成规则并提交，用户通过 `warp-vps update` 获取新快照。

## 支持系统

优先支持：

- Debian 12
- Debian 13
- Ubuntu 22.04 LTS / 24.04 LTS
- CentOS 8
- RHEL 8 / 9
- Rocky Linux 8 / 9
- AlmaLinux 8 / 9

CentOS 7 不支持。Cloudflare WARP 官方 Linux 支持列表当前只覆盖 CentOS 8、RHEL 8/9、Debian 12/13、Ubuntu 22.04/24.04 等现代发行版。

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

- `warp-vps test`：验证 WARP SOCKS、redsocks、nftables、Google TCP 命中、UDP/443 阻断、IPv6 防泄漏规则。
- `warp-vps restart`：重启本地 WARP 分流链路并重新加载规则。
- `warp-vps update`：从配置的 GitHub raw 地址拉取最新脚本和固定规则快照。
- `warp-vps uninstall`：停止服务并把安装文件移动到备份目录，系统包保留。

## 重要边界

- 不做全局 WARP。
- 不修改 Xray、sing-box、Hysteria、3x-ui 等业务配置。
- 不做域名级 DNS 分流。
- 不承诺透明代理 UDP，UDP/443 通过阻断强制回落 TCP。
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
print("rules ok")
PY
```

最终发布前还应在干净 Debian/Ubuntu/CentOS/RHEL/Rocky/AlmaLinux VPS 上做真实安装测试。

## 参考项目

本项目受到以下项目启发并参考了部分思路：

- https://github.com/vps8899/warp-google-unlock
- https://github.com/yonggekkk/warp-yg
- https://github.com/lmc999/RegionRestrictionCheck

相关官方文档：

- https://developers.cloudflare.com/warp-client/get-started/linux/
- https://developers.cloudflare.com/warp-client/get-started/
- https://knowledge.workspace.google.com/admin/security/obtain-google-ip-address-ranges
- https://docs.cloud.google.com/appengine/docs/standard/outbound-ip-addresses
