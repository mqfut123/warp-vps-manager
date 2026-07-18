# WARP VPS Manager

只把 Google 相关流量转到 Cloudflare WARP，其他流量继续使用 VPS 原生出口。

适合 VPS 原生 IP 无法正常使用 Gemini、Google Search 或 YouTube Premium，又不想修改 Xray、sing-box、Hysteria、3x-ui 配置的情况。

## 安装

使用 `root` 用户运行：

```bash
curl https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash
```

模式选择直接回车时使用 Socks5，端口直接回车时随机选择空闲端口。输错内容会重新询问，不需要重跑脚本。

如果安装中途失败，处理报错后再次运行同一条命令即可，不需要先卸载。

## 模式选择

| 模式 | 适合谁 | 效果 |
|---|---|---|
| Socks5 | 大多数用户，直接选这个 | Google IPv4 TCP 走 WARP。UDP/443 和 Google IPv6 会被阻断，让支持回落的客户端改用 TCP |
| WireGuard | 需要 UDP 或 QUIC 的用户 | 命中 Google IP 规则的 IPv4、IPv6、TCP 和 UDP 都走 WARP |

Socks5 对现有网络改动较少。WireGuard 会增加网卡和路由，如果 VPS 已经有 WireGuard 或复杂路由，请先确认不会冲突。

## 和其他方案的区别

最大的区别是分流规则的精度。WARP VPS Manager 使用 Google 官方 IP 列表，并排除 Google Cloud 客户地址，尽量只处理 Google 自有服务流量。

| 方案 | 适合场景 | 主要区别 |
|---|---|---|
| WARP VPS Manager | 只想处理 Google 相关流量 | 规则从 `goog.json` 中减去 `cloud.json`，不会把 Google Cloud 客户地址整段塞进 WARP |
| [warp-google-unlock](https://github.com/vps8899/warp-google-unlock) | 想快速处理 Google 或 Gemini | [直接使用 `34.0.0.0/9` 等大网段](https://github.com/vps8899/warp-google-unlock/blob/main/warp-google.sh#L177-L199)，规则较粗，与 Google Cloud 客户地址存在重叠，可能把无关 IP 一起送进 WARP |
| [warp-yg](https://github.com/yonggekkk/warp-yg) | 想要完整的 WARP 工具箱 | 功能更多，可管理 wgcf、warp-go、WARP+、团队账户和对端 IP |
| Xray 或 sing-box 分流 | 愿意自己维护代理配置 | 可以按域名精细分流，但只对经过代理程序的流量生效 |
| 全局 WARP | 整台 VPS 都要使用 WARP 出口 | 配置直接，但所有业务流量都会更换出口 |

## 管理命令

| 命令 | 用途 |
|---|---|
| `warp-vps status` | 查看当前配置和链路状态 |
| `warp-vps test` | 测试分流是否正常 |
| `warp-vps unlock-check` | 检测 Gemini 和 YouTube Premium |
| `warp-vps restart` | 重启 WARP 分流链路 |
| `warp-vps update` | 更新脚本和 Google IP 规则 |
| `warp-vps logs` | 查看最近的服务日志 |
| `warp-vps uninstall` | 交互卸载，并询问是否一并卸载相关运行依赖 |
| `warp-vps uninstall --yes` | 非交互卸载项目，保留依赖 |
| `warp-vps uninstall all` | 非交互卸载项目及 WARP、redsocks、wireguard-tools |

安装完成后如果访问异常，先运行：

```bash
warp-vps status
warp-vps logs
```

## 卸载

直接运行 `warp-vps uninstall`，会询问是否一并卸载相关运行依赖；直接回车默认保留依赖。

脚本或批量操作可使用 `warp-vps uninstall --yes`，无需交互并保留依赖。需要连依赖一起卸载时使用 `warp-vps uninstall all`，同样无需交互。

三种卸载方式都会先停止自动修复，并确认分流规则已经失效；如果无法确认，卸载会立即中止，不会继续移动文件或显示成功。`all` 会强制移除 `cloudflare-warp`、`redsocks` 和 `wireguard-tools`，包括卸载前已经存在的这些软件包；它不会主动执行 `autoremove`，curl、Python、iproute 等共享基础包不在直接卸载清单中，但包管理器仍可能按依赖关系处理关联软件包。

## 使用前需要知道

- 这是 IP 分流，不是域名识别。Google 调整 IP 后，请运行 `warp-vps update` 获取新规则。
- Socks5 模式不能转发 UDP。无法回落到 TCP 的客户端可能连接失败。
- 如果系统已经安装 Cloudflare WARP 客户端，Socks5 模式会复用它并切换到本地代理模式。保留依赖卸载不会恢复客户端原来的模式；`all` 会直接卸载该客户端。
- 卸载时项目文件和脚本创建的 Swap 会移到 `/var/backups/warp-vps-manager/`，不会永久删除。

## IP 规则来源

规则来自 Google 官方的 [公网 IP 列表](https://www.gstatic.com/ipranges/goog.json)，并排除 [Google Cloud 客户外部 IP](https://www.gstatic.com/ipranges/cloud.json)。

本项目使用 [MIT License](LICENSE)。
