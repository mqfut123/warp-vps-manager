# WARP VPS Manager

按所选模式处理 Google 官方地址范围，其他流量继续使用 VPS 原生出口。

适合 VPS 原生 IP 无法正常使用 Gemini、Google Search 或 YouTube Premium，又不想修改 Xray、sing-box、Hysteria、3x-ui 配置的情况。

## 安装

使用 `root` 用户运行：

```bash
curl https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash
```

全新安装的默认组合是 **WireGuard + 1G Swap**：模式选择直接回车使用 WireGuard；系统没有 Swap 时，下一步直接回车创建 1G。已有安装会显示当前模式，直接回车保持不变；已有 Swap 时不会重复创建。首次选择 Socks5 时，端口直接回车会随机选择空闲端口；同模式重装时直接回车会保留当前端口。输错内容会重新询问，不需要重跑脚本。

重装或切换模式时，目标模式所需依赖已经齐全就直接复用，不会重复运行系统包管理器；确实缺少依赖时才会安装，并在停用旧分流前完成。健康的同模式 WireGuard 或 WARP SOCKS 后端会保持运行，只重新加载本项目规则；切换目标会先准备配置，暂停旧分流后再检查接口、端口、规则和代表性路由，不等待 Google/Cloudflare HTTP 响应或 WireGuard 握手。后续本地安装失败时会尝试恢复原模式。

如果安装中途失败，处理报错后再次运行同一条命令即可，不需要先卸载。

## 模式选择

| 模式 | 适合谁 | 效果 |
|---|---|---|
| WireGuard | 大多数用户，直接回车使用 | 命中 Google IP 规则的 IPv4、IPv6、TCP、UDP 和 QUIC 都走 WARP |
| Socks5 | 只需要兼容代理模式的用户 | Google IPv4 TCP 走 WARP，IPv4 UDP 和 QUIC 使用 VPS 原生出口，Google IPv6 继续拒绝 |

Socks5 对现有网络改动较少。WireGuard 会增加网卡和路由，如果 VPS 已经有 WireGuard 或复杂路由，请先确认不会冲突。

Socks5 无法通过本地代理转发 UDP，因此同一 Google 会话可能同时出现 WARP 和 VPS 原生出口，增加触发 Google 异常流量检查的概率。需要 Google IPv4、IPv6、TCP、UDP 和 QUIC 使用同一 WARP 出口时，请选择 WireGuard。

## 切换模式

重新运行安装命令即可切换模式，不需要先卸载：

```bash
curl https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash
```

安装器会显示当前模式。直接回车保持当前模式；输入 `2` 可从 Socks5 切换到 WireGuard，输入 `1` 可从 WireGuard 切换到 Socks5。切换时会先准备并校验目标模式所需依赖和配置，再停用旧模式服务和分流规则并启用新规则；不会主动删除另一模式已经安装的系统依赖。

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
| `warp-vps status` | 查看本地服务、接口、端口和分流规则状态，不依赖外部站点 |
| `warp-vps test` | 运行分流和外部连通性诊断；外部探测失败只会提示，不改变运行状态 |
| `warp-vps unlock-check` | 检测当前 IPv4 出口的 Gemini 和 YouTube Premium；安装完成后自动运行，也可手动运行 |
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

安装程序会在本地配置确认完成后自动运行 `unlock-check`。Google、Cloudflare、DNS 或其他外部目标暂时超时或不可用时，检测结果只作提示，不会把已经完成的安装判为失败，也不会停止服务或撤销分流规则。手动运行 `test` 或 `unlock-check` 同样不会改变项目运行状态。

自动健康检查定时器属于辅助恢复功能，不承载分流流量；它未能启用时会显示信息，但不会撤销已经正常工作的 WireGuard/Socks5 接口、端口或规则，也不会单独导致重启、更新失败。重启或更新前仍会等待正在执行的自动修复退出，避免同时改动接口和路由。

## 卸载

直接运行 `warp-vps uninstall`，会询问是否一并卸载相关运行依赖；直接回车默认保留依赖。

脚本或批量操作可使用 `warp-vps uninstall --yes`，无需交互并保留依赖。需要连依赖一起卸载时使用 `warp-vps uninstall all`，同样无需交互。

三种卸载方式都会先停止自动修复，并确认分流规则已经失效；如果无法确认，卸载会立即中止，不会继续移动文件或显示成功。`all` 会强制移除 `cloudflare-warp`、`redsocks` 和 `wireguard-tools`，包括卸载前已经存在的这些软件包；它不会主动执行 `autoremove`，curl、Python、iproute 等共享基础包不在直接卸载清单中，但包管理器仍可能按依赖关系处理关联软件包。

## 使用前需要知道

- 这是 IP 分流，不是域名识别。Google 调整 IP 后，请运行 `warp-vps update` 获取新规则。
- Socks5 模式不能通过 WARP 本地代理转发 UDP。Google IPv4 UDP 和 QUIC 会使用 VPS 原生出口，Google IPv6 仍会被拒绝；如果需要双栈和 UDP 都走 WARP，请使用 WireGuard。
- 如果系统已经安装 Cloudflare WARP 客户端，Socks5 模式会复用它并切换到本地代理模式。保留依赖卸载不会恢复客户端原来的模式；`all` 会直接卸载该客户端。
- 卸载时项目文件和脚本创建的 Swap 会移到 `/var/backups/warp-vps-manager/`，不会永久删除。

## IP 规则来源

规则来自 Google 官方的 [公网 IP 列表](https://www.gstatic.com/ipranges/goog.json)，并排除 [Google Cloud 客户外部 IP](https://www.gstatic.com/ipranges/cloud.json)。

本项目使用 [MIT License](LICENSE)。
