# WARP VPS Manager

WARP VPS Manager 是一个面向 Linux VPS 的一键 WARP 分流工具，用于把命中 Google consumer CIDR 的本机出站 TCP 流量走 Cloudflare WARP。这个 CIDR 范围覆盖常见 Google、YouTube、Gemini 出站目标，并默认排除 Google Cloud 客户外部 IP。

它使用 Cloudflare 官方 WARP 客户端的本地 SOCKS 模式，再通过 `redsocks` 和 `nftables` 做系统级 TCP 透明分流。它不修改 Xray、sing-box、Hysteria 等代理服务配置。

本项目受到以下项目启发并参考了部分思路：

- https://github.com/vps8899/warp-google-unlock
- https://github.com/yonggekkk/warp-yg
- https://github.com/lmc999/RegionRestrictionCheck

## 功能

- 必须使用 `root` 安装，非 root 会立即退出。
- 自动安装缺失依赖。
- 安装时询问 WARP SOCKS 端口。
- 直接回车时，随机选择一个未被占用的高位端口。
- 命中 Google consumer CIDR 的 TCP 流量走 WARP。
- 命中 Google/YouTube CIDR 的 UDP/443 会被阻断，避免 QUIC 绕过 WARP。
- 命中 Google/YouTube CIDR 的 IPv6 会被阻断，避免 IPv6 泄漏。
- 规则快照固定保存在 GitHub 仓库中，不在用户机器后台自动抓取 Google 规则。
- 用户通过 `warp-vps update` 同步脚本和固定规则快照。

## 安装

建议准备至少 1GB 可用磁盘空间。Ubuntu/Debian 上的 `cloudflare-warp` 官方包会拉取较多图形/桌面相关依赖，这是 Cloudflare 官方包依赖链导致的，不是本脚本额外启用 GUI。

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh)'
```

使用 fork 或自定义 raw 地址：

```bash
WARP_VPS_REPO_BASE="https://raw.githubusercontent.com/YOUR_NAME/warp-vps-manager/main" \
sudo -E bash -c 'bash <(curl -fsSL "$WARP_VPS_REPO_BASE/install.sh")'
```

安装完成后，脚本会明确显示实际使用的 WARP SOCKS 端口。

## 管理命令

```bash
warp-vps status
warp-vps test
warp-vps restart
warp-vps update
warp-vps logs
warp-vps uninstall
```

`warp-vps update` 只从配置的 GitHub raw 地址拉取最新项目文件和固定 CIDR 快照，不会直接抓取 Google 官方实时规则。

## 支持系统

优先支持：

- Debian 12
- Ubuntu 22.04 / 24.04
- Rocky Linux 9
- AlmaLinux 9

如果 VPS 或容器内核缺少 `nftables` NAT 能力，安装会 fail-fast。

## 重要边界

- 这是 IP/CIDR 系统级分流，不是域名级分流。
- 主链路使用 SOCKS，所以不承诺透明代理 UDP。
- Google/YouTube UDP/443 会被阻断以强制 TCP 回落。
- Google Cloud 客户外部 IP 默认排除，规则生成方式是 `goog.json - cloud.json`。
- 卸载不会永久删除安装文件，而是移动到带时间戳的备份目录。
- 卸载不会移除系统包、Cloudflare repo/key、`cloudflare-warp`、`redsocks`、`nftables` 等依赖。
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

最终发布前还应在干净 Debian/Ubuntu/Rocky/AlmaLinux VPS 上做一次真实安装测试。
