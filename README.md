# WARP VPS Manager

**让 Google 服务走 WARP，其他目标继续使用 VPS 原生出口。**

适合在 Linux VPS 上运行代理、网站或应用，希望为 Gemini、YouTube 等 Google 服务更换出口的用户。支持 Google 精准分流和全局 WARP，安装后可通过 `warp-vps` 统一管理。

[![CI](https://github.com/mqfut123/warp-vps-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/mqfut123/warp-vps-manager/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mqfut123/warp-vps-manager)](https://github.com/mqfut123/warp-vps-manager/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 一键安装

使用 `root` 用户运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh)
```

全新交互安装默认选择 **Google 精准分流 + 1G Swap**，并根据出站 UDP 探测结果建议 WireGuard 或 Socks5。检测到已有项目安装时，再运行同一命令会进入管理菜单。

<details>
<summary>安装默认值与 Swap 选项</summary>

安装器先处理 Swap，再选择 Google 精准分流或全局 WARP，最后选择运行模式。

非交互安装、重装或切换省略 `--swap` 时会尝试创建 1G Swap；磁盘空间不足，或创建失败且已确认清理完成时，会警告并继续安装。无法确认清理完成时仍停止。显式使用 `--swap auto` 或 `--swap N` 时保持严格语义，创建条件不满足会停止安装；`--swap none` 明确跳过。

</details>

## 为什么选择 WARP VPS Manager

- **分流范围有明确依据。** 使用 Google 官方公网 IP 列表，并排除 Google Cloud 客户地址，避免把托管在 Google Cloud 上的其他服务一并切换出口。
- **已有代理配置继续用。** 在系统出站层完成分流，无需逐项修改 Xray、sing-box、Hysteria 或 3x-ui 的代理配置。
- **检测和换 IP 一起完成。** 查看当前 WARP 公网 IPv4，分别检测原生与 WARP 出口的 Gemini、YouTube Premium 可用情况。需要换 IP 时，运行 `warp-vps change-ip` 自动更换并复检。
- **安装后也方便维护。** 更新程序与规则、查看日志、切换 WireGuard / Socks5、调整路由范围和卸载，都能在同一管理菜单中完成。

## 和其他方案怎么选

| 方案 | 主要特点 | 适合您的需求 |
|---|---|---|
| **WARP VPS Manager** | Google 官方 IP 范围，排除 Cloud 客户地址；支持两种后端和精准 / 全局切换 | 重点改善 Google 出口，同时保留现有代理配置，并统一管理检测、换 IP 和维护 |
| [warp-google-unlock](https://github.com/vps8899/warp-google-unlock) | 动态域名分流与预置 Google 网段结合，目标包含 Google、ChatGPT、Claude | 希望按域名动态分流 Google 及更多 AI 服务 |
| [warp-yg](https://github.com/yonggekkk/warp-yg) | 提供 wgcf / warp-go 切换、WARP+ 和团队账户管理等功能 | 需要多种 WARP 后端及账户管理工具 |
| [Xray](https://xtls.github.io/config/routing.html) / [sing-box](https://sing-box.sagernet.org/configuration/route/rule/) 分流 | 按域名、IP 等条件为进入代理程序的流量选择出站 | 已有代理体系，需要自行定义不同服务的出口规则 |

## 两种路由范围

- **精准分流 Google（默认）**：只处理规则内的 Google 目标流量。
- **全局走 WARP**：WireGuard 接管公网 IPv4、IPv6 与全部协议；Socks5 接管 VPS 主动发起的公网 IPv4 TCP。

WireGuard 全局模式让未绑定原生源地址的公网 IPv4、IPv6、TCP、UDP 和 QUIC 全部走 WARP；现有及新入站连接回包、显式绑定 VPS 原生源地址的流量和局域网路由保留原生路径。Socks5 不承载 UDP 或 IPv6；其全局模式接管 VPS 主动发起的公网 IPv4 TCP，入站连接回包保持原生路径，并继续拒绝 Google IPv4 UDP/443（QUIC）和 Google IPv6；其他非 Google UDP 与 IPv6 仍使用 VPS 原生出口。

## 选择运行模式

| 模式 | Google 精准分流 | 全局走 WARP |
|---|---|---|
| **WireGuard** | Google IPv4、IPv6、TCP、UDP 和 QUIC | 公网 IPv4、IPv6 与全部协议 |
| **Socks5** | Google IPv4 TCP；Google IPv4 UDP/443（QUIC）与 Google IPv6 拒绝 | VPS 主动发起的公网 IPv4 TCP；Google IPv4 UDP/443（QUIC）与 Google IPv6 继续拒绝 |

Socks5 会让支持回落的客户端从 QUIC 改用经 WARP 转发的 TCP；其他 Google IPv4 UDP 端口和非 Google 目标 UDP 不受影响。

<details>
<summary>模式建议与对端验证</summary>

全新交互安装会向 Cloudflare STUN UDP/3478 发出有界探测。收到有效回包时，直接回车默认选择 WireGuard；已完成探测但未收到有效回包时，直接回车默认选择 Socks5，并提示 WireGuard 只使用 UDP、不会回退 TCP。检测无法完成时保留 WireGuard 默认；显式输入 `1` 或 `2` 始终按所选模式安装。该探测只用于默认建议；WireGuard 配置生成后，安装器会对域名当前解析出的 WARP 地址依次尝试默认端口 UDP/2408 和 [Cloudflare 公布的 WireGuard 回退端口](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/firewall/#warp-ingress-ip) UDP/500、UDP/1701、UDP/4500，只有 Google IPv4、Google IPv6 均返回、WireGuard 最近握手存在且接收字节增长时才继续安装。更新、开机和显式重启也会重新选择当前可用对端，但不会把解析出的 IP 或运行时端口写死到配置文件。所有对端都失败时会清除本项目路由并提示改用 Socks5。

WARP 对端使用 IPv4 还是 IPv6，只决定 WireGuard 加密包如何到达 Cloudflare，不限制隧道内承载的地址族。底层使用已验证的 IPv4 对端时，Google IPv6 仍通过 WireGuard 的 IPv6 地址和路由走 WARP；只有 Socks5 模式不承载 IPv6。

</details>

## 运行条件

- 使用 `systemd` 的 Linux VPS
- 在 Bash（或支持进程替换的 shell）中运行，并预装 curl；安装器会补齐 Python 3 和所选模式缺少的运行依赖
- 使用 APT、DNF 或 YUM，并能从当前配置的软件源取得所选模式的依赖
- WireGuard 模式需要系统能够通过 `wg-quick` 创建项目网卡并允许出站 UDP；WireGuard 不会回退 TCP；全局范围同时需要 nftables
- Socks5 模式需要 nftables `OUTPUT` NAT，并且系统与架构位于 [Cloudflare WARP Client 当前支持范围](https://developers.cloudflare.com/warp-client/get-started/)；RHEL 9 及以上版本需要先启用 EPEL

安装器按系统实际提供的包管理器和网络能力选择安装路径，不依赖固定发行版版本表。

<details>
<summary>依赖安装与 wgcf 校验</summary>

依赖完整时不会调用包管理器；缺少普通依赖时只提交未安装的软件包，不执行全局 `apt update`，也不主动清理或刷新 DNF/YUM 元数据。首次新增 Cloudflare WARP APT 源时只获取该源的索引；已有源当前没有可用候选时，安装器会提示先由用户运行 `apt update`。已安装但不完整的 Cloudflare WARP 只重装自身，其他已安装组件不会顺带升级。

WireGuard 配置固定使用 `wgcf v2.2.32`，不会动态追随 GitHub `latest`。下载的官方二进制通过对应架构的官方 `checksums.txt` 校验后才会启用。

</details>

## 管理命令

直接运行 `warp-vps` 或 `warp-vps menu` 打开交互式管理菜单。

| 命令 | 用途 |
|---|---|
| `warp-vps ip` | 只输出当前 WARP 公网 IPv4，便于直接复制或用于脚本 |
| `warp-vps status` | 查看当前 WARP 公网 IPv4、配置、服务、接口、端口和分流服务运行态 |
| `warp-vps test` | 运行分流与外部连通性诊断 |
| `warp-vps native-unlock-check` | 绕过 WARP 分流，检测原生出口的 Gemini 和 YouTube Premium |
| `warp-vps unlock-check [--strict-exit]` | 检测当前 WARP IPv4 出口的 Gemini 和 YouTube Premium；严格退出模式仅在两项均明确可用时成功 |
| `warp-vps change-ip [--policy all\|any]` | 最多更换 10 次 WARP 注册；默认两项服务均明确可用才停止 |
| `warp-vps restart` | 重启 WARP 分流链路 |
| `warp-vps update` | 更新程序与 Google IP 规则；不安装或升级运行依赖，旧版规则差异不会阻止更新 |
| `warp-vps reinstall --scope global` | 保持运行模式并切换到全局 WARP |
| `warp-vps reinstall --scope google` | 保持运行模式并切回 Google 精准分流 |
| `warp-vps switch wireguard` | 切换到 WireGuard |
| `warp-vps switch socks --socks-port auto` | 切换到 Socks5 并自动选择端口 |
| `warp-vps logs` | 查看最近的服务日志 |

<details>
<summary>检测、换 IP 与非交互用法</summary>

进入“重装或切换”后，可重新选择路由范围和 Socks5 / WireGuard 模式；运行模式直接回车保持当前模式。非交互重装未指定 `--scope` 时保留当前范围；全新非交互安装的路由范围默认使用 Google 精准分流，运行模式默认 WireGuard，可用 `--scope` 与 `--mode` 显式指定。

安装完成、管理菜单和 `warp-vps status` 都会显示当前 WARP 公网 IPv4。`warp-vps ip` 成功时只向标准输出写入这个 IPv4；查询会沿当前 WireGuard 或 Socks5 的 WARP 路径执行，不把 VPS 原生公网 IP 当作 WARP IP。暂时无法确认时，交互界面显示“暂时无法获取”，不影响已完成的安装、菜单操作或本地运行状态检查。

`native-unlock-check` 需要 root 且仅在主动运行时检测：取原生默认接口的第一个 global IPv4，没有 IPv4 时取第一个 global IPv6；通过同一路径显示 Cloudflare Trace 返回的公网 IP 和地区，再复用现有 Gemini、YouTube Premium 判断。它不会暂停服务、修改规则或加入安装后的自动检测；结果只供参考，不影响安装、更新、重启或健康检查。

`unlock-check`、安装完成检测、`change-ip` 与 `native-unlock-check` 共用相同的页面判定。每项使用首个成功的 HTTP 响应，只有传输失败时才重试一次，不合并两份成功页面。Gemini 返回 403 / 451 或受限地区时显示不可用；否则，命中两个已知正向 marker 中任意一个，或页面返回受支持地区时显示可用，其余情况显示无法确认；Gemini 地区码只参与内部判断，不在结果中展示。YouTube Premium 的三种明确不可用文案或最终重定向到 `google.cn` 域名时优先显示不可用；否则，只有 HTTP 2xx 响应包含 `premiumPurchaseButton`、`manageSubscriptionButton`、月付标记、`ad-free` 或精确的 `SPunlimited` browseId 任一信号时才显示可用。YouTube 的页面地区只用于结果说明，不作为 Premium 可用证据；单纯 HTTP 成功或普通标题也不能证明解锁。检测请求不使用环境代理、Cookie 或本地缓存。单独运行 `unlock-check` 时仍会逐项显示结果；默认作为只读诊断返回成功，增加 `--strict-exit` 后只有两项都明确可用才返回成功。

安装成功后会先显示当前 WARP 公网 IPv4，再运行一次 `unlock-check --strict-exit`。两项均明确可用时直接结束；未全部通过时始终提示稍后可运行 `warp-vps change-ip`。交互安装会再询问是否立即更换，提示为 `[Y/n]`，直接回车或输入 Y / yes 会执行 `warp-vps change-ip --policy all`，其他输入或读取结束则不更换；非交互安装不读取输入，也不自动更换。IP 查询、检测或更换失败不会改变已经完成的安装结果。

`change-ip` 保持当前 WireGuard / Socks5 模式、Google 精准 / 全局路由范围和 Socks5 端口，通过重新注册 WARP 获取新出口。执行时先显示更换前的 WARP 公网 IPv4；每次注册恢复数据面后，先显示该次更换后的实际 IPv4，再执行 Gemini 和 YouTube Premium 检测。即使该次没有达到停止条件并继续下一次，更换到的 IP 也会保留在输出中；成功或用完 10 次后会再次标明最后一轮的“最终 WARP 公网 IPv4”，不会为最终文案额外查询一次。某轮暂时无法获取 IP 时会如实显示，不沿用上一轮结果，也不阻止随后的解锁检测。

默认停止策略为 `all`，要求 Gemini 与 YouTube Premium 均明确可用；交互运行且未指定策略时以 `[Y/n]` 确认该默认值，选择 n 改为任一项明确可用即可停止。非交互运行同样默认 `all`，自动化可通过 `--policy all` 或 `--policy any` 明确指定。每轮恢复当前数据面后立即复检，最多尝试 10 次。Socks5 模式只更换本项目管理的 Free 注册，不替换用户原有的 WARP Client、Unlimited 或组织账户。Socks5 全局范围更换注册时会先暂停项目透明分流，避免 WARP Client 注册请求被旧规则重定向；完成注册和本地代理配置后恢复原范围，并验证完整数据面。

</details>

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
