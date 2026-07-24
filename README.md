# WARP VPS Manager

按所选模式处理 Google 官方地址范围，其他流量继续使用 VPS 原生出口。

适合 VPS 原生 IP 无法正常使用 Gemini、Google Search 或 YouTube Premium，又不想修改 Xray、sing-box、Hysteria、3x-ui 配置的情况。

## 安装

使用 `root` 用户运行：

```bash
bash -o pipefail -c \
  'curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash'
```

全新安装的默认组合是 **WireGuard + 1G Swap**：模式选择直接回车使用 WireGuard；系统没有 Swap 时，下一步直接回车创建 1G。检测到已有项目安装时，再运行上面的安装命令会进入全局管理菜单，不会立即重装；在菜单中选择“重装或切换模式”后，直接回车保持当前模式，也可选择另一模式。已有 Swap 时不会重复创建。首次选择 Socks5 时，端口直接回车会随机选择空闲端口；同模式重装时直接回车会保留当前端口。输错内容会重新询问，不需要重跑脚本。

重装或切换模式时，目标模式所需依赖已经齐全就直接复用，不会重复运行系统包管理器；确实缺少依赖时才会安装，并在停用旧分流前完成。健康的同模式 WireGuard 或 WARP SOCKS 后端会保持运行，只重新加载本项目规则；切换目标会先准备配置，暂停旧分流后再检查接口、端口、规则和代表性路由，不等待 Google/Cloudflare HTTP 响应或 WireGuard 握手。后续本地安装失败时会尝试恢复原模式。

如果安装中途失败，处理报错后再次运行同一条命令即可，不需要先卸载。首次安装且没有可复用的 WARP 注册、账户或 WireGuard 配置时，必要的程序下载、Cloudflare 注册或配置生成失败（包括限流 `429` 或超时）会返回非零，因为此时还没有可运行的目标配置；脚本不会把这种情况伪装成安装成功，稍后重试即可。它与本地安装已经完成后自动运行的解锁检测不同：后者依赖外部站点，失败只作提示，不会撤销已成功的安装。

自动化环境使用明确的非交互入口，不会读取标准输入或 `/dev/tty`：

```bash
bash -o pipefail -c \
  'curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash -s -- --install --non-interactive'
```

省略选项时仍采用全新默认值 WireGuard + 1G Swap；已有安装则保持当前模式，已有 Swap 不会重复创建。可按需增加 `--mode wireguard|socks|keep`、`--swap auto|none|N`（`N` 为 GiB）和 `--socks-port auto|PORT`。例如，全新非交互安装 Socks5 并自动选择端口：

```bash
bash -o pipefail -c \
  'curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash -s -- --install --non-interactive --mode socks --socks-port auto'
```

`--swap none` 表示明确跳过 Swap；非交互创建 Swap 失败时会撤销本次创建并返回失败，不会停下来等待人工输入。菜单和普通交互安装必须有终端；无终端时会立即提示应使用的非交互入口。

## 模式选择

| 模式 | 适合谁 | 效果 |
|---|---|---|
| WireGuard | 大多数用户，直接回车使用 | 命中 Google IP 规则的 IPv4、IPv6、TCP、UDP 和 QUIC 都走 WARP |
| Socks5 | 只需要兼容代理模式的用户 | Google IPv4 TCP 走 WARP，Google IPv4 UDP/443（QUIC）和 Google IPv6 拒绝 |

Socks5 对现有网络改动较少。WireGuard 会增加网卡和路由，如果 VPS 已经有 WireGuard 或复杂路由，请先确认不会冲突。

Socks5 无法通过本地代理转发 UDP，因此会拒绝命中 Google IPv4 规则的 UDP/443（QUIC），让支持回落的客户端改用经 WARP 的 TCP；其他 Google IPv4 UDP 端口和非 Google 目标 UDP 不受影响，Google IPv6 继续拒绝。需要 Google IPv4、IPv6、TCP、UDP 和 QUIC 使用同一 WARP 出口时，请选择 WireGuard。

## 切换模式

直接运行 `warp-vps`，选择“重装或切换模式”，不需要先卸载。也可以重新运行安装命令进入同一个管理菜单：

```bash
bash -o pipefail -c \
  'curl -fsSL https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash'
```

进入重装或切换流程后会显示当前模式。直接回车保持当前模式；输入 `2` 可从 Socks5 切换到 WireGuard，输入 `1` 可从 WireGuard 切换到 Socks5。切换时会先准备并校验目标模式所需依赖和配置，再停用旧模式服务和分流规则并启用新规则；不会主动删除另一模式已经安装的系统依赖。

脚本或批量运维无需进入菜单：

```bash
warp-vps reinstall
warp-vps switch wireguard
warp-vps switch socks --socks-port auto
```

`reinstall` 默认保持当前模式；也可使用 `warp-vps reinstall --mode wireguard|socks`。这些命令都委托给同一个安装事务，与菜单切换具有相同的校验、回滚和本地验收逻辑。

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

安装完成后，在终端直接运行 `warp-vps` 或 `warp-vps menu` 会打开交互式管理菜单，可查看状态、诊断、检测解锁、重启、更新、重装或切换模式、查看日志和卸载。更新、重装或卸载成功后菜单会结束；再次运行 `warp-vps` 即可继续管理。所有菜单动作都有适合脚本的显式命令；除交互菜单和不带范围的 `uninstall` 外，以下命令不会读取输入：

| 命令 | 用途 |
|---|---|
| `warp-vps` / `warp-vps menu` | 打开交互式管理菜单 |
| `warp-vps status` | 查看本地服务、接口、端口和分流规则状态，不依赖外部站点 |
| `warp-vps test` | 运行分流和外部连通性诊断；外部探测失败只会提示，不改变运行状态 |
| `warp-vps unlock-check` | 检测当前 IPv4 出口的 Gemini 和 YouTube Premium；安装完成后自动运行，也可手动运行 |
| `warp-vps restart` | 重启 WARP 分流链路 |
| `warp-vps update` | 更新脚本和 Google IP 规则 |
| `warp-vps reinstall` | 非交互重装并保持当前模式 |
| `warp-vps reinstall --mode wireguard\|socks` | 非交互重装或选择目标模式；还可传入 `--swap`、`--socks-port` |
| `warp-vps switch wireguard\|socks` | 非交互切换到指定模式；Socks5 可增加 `--socks-port auto\|PORT` |
| `warp-vps logs` | 查看最近的服务日志 |
| `warp-vps uninstall` | 交互卸载，并询问是否一并卸载相关运行依赖 |
| `warp-vps uninstall --yes` | 非交互卸载项目，保留依赖 |
| `warp-vps uninstall all` | 非交互卸载项目及 WARP、redsocks、wireguard-tools |

显式命令会严格检查参数，拼错或多余参数不会继续执行。退出码 `0` 表示请求的本地动作已完成，`2` 表示命令用法错误或在无终端环境请求交互菜单；其他非零值表示真实失败（项目自身报错通常为 `1`，`curl`、包管理器等外部程序可能保留自己的退出码），自动化不应只匹配 `1`。`test` 和 `unlock-check` 的外部探测失败仍只作诊断提示，不会把正常本地运行态改成失败。

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
- Socks5 模式不能通过 WARP 本地代理转发 UDP。项目只拒绝命中 Google IPv4 规则的 UDP/443（QUIC）以及 Google IPv6；无法回落到 TCP 的请求会失败。如果需要双栈和全部 UDP 都走 WARP，请使用 WireGuard。
- 如果系统已经安装 Cloudflare WARP 客户端，Socks5 模式会复用它并切换到本地代理模式。保留依赖卸载不会恢复客户端原来的模式；`all` 会直接卸载该客户端。
- 卸载时项目文件和脚本创建的 Swap 会移到 `/var/backups/warp-vps-manager/`，不会永久删除。

## IP 规则来源

规则来自 Google 官方的 [公网 IP 列表](https://www.gstatic.com/ipranges/goog.json)，并排除 [Google Cloud 客户外部 IP](https://www.gstatic.com/ipranges/cloud.json)。

本项目使用 [MIT License](LICENSE)。
