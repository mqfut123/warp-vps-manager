# WARP VPS Manager

把命中 Google 官方 IP 快照的出站流量转到 Cloudflare WARP，其他流量继续使用 VPS 原生出口。

脚本在系统出站层处理分流，不修改 Xray、sing-box、Hysteria 或 3x-ui 配置。安装时可以选择 Socks5 或 WireGuard 模式。

## 安装

切换到 `root` 用户，运行：

```bash
curl https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main/install.sh | bash
```

如果系统没有 `curl`，请先通过系统包管理器安装。

模式选择直接回车时使用 Socks5。Socks5 端口也可以直接回车，脚本会选择一个空闲的高位端口。

脚本会先收齐所有选项，再修改系统。普通输入错误会留在当前问题重新询问。开始安装依赖前，`warp-vps` 命令已经写入系统；后续失败时可以查看日志、卸载，或直接重跑安装器。

## 两种模式

| 模式 | 适合场景 | 分流行为 |
|---|---|---|
| Socks5 | 默认选择，适合大多数 VPS | Google IPv4 TCP 经 WARP 转发。Google UDP/443 和目标 IPv6 会被阻断，让支持回落的客户端改用 TCP |
| WireGuard | 明确需要 UDP 或 QUIC | 命中 Google CIDR 的 IPv4、IPv6、TCP 和 UDP 都经 WARP 转发 |

Socks5 使用 Cloudflare 官方 WARP 客户端、redsocks 和 nftables，不接管默认路由。WireGuard 会增加单独的网卡及目标路由，安装器通过实际拉起接口、握手和路由结果判断系统是否支持。

## 支持环境

系统必须运行 `systemd`，并提供 `apt-get`、`dnf` 或 `yum`。安装器按这些实际能力选择安装路径，不按发行版名称或版本号提前拒绝。

Debian、Ubuntu 及其 APT 衍生系统走 APT 路径。Fedora、CentOS、RHEL、Rocky Linux、AlmaLinux 及其他 RPM 系统走 DNF 或 YUM 路径。Socks5 模式还要求 nftables `OUTPUT` NAT 和当前系统、架构可用的 Cloudflare WARP 包。Cloudflare 的实际发布范围以其 [Linux 软件包页面](https://pkg.cloudflareclient.com/) 为准。

WireGuard 模式不依赖 nftables、iptables 或 `/dev/net/tun`。系统必须能通过 `wg-quick` 实际创建并配置项目网卡。

建议至少保留 1 GB 可用磁盘空间。Cloudflare 官方软件包可能安装桌面相关依赖，这是其软件包本身的依赖关系。

## 管理命令

| 命令 | 用途 |
|---|---|
| `warp-vps status` | 查看当前模式、规则快照和链路状态 |
| `warp-vps test` | 运行一次链路自检 |
| `warp-vps unlock-check` | 检测当前 IPv4 出口的 Gemini 和 YouTube Premium 状态 |
| `warp-vps restart` | 重启 WARP 分流链路并重新加载规则 |
| `warp-vps update` | 更新脚本和仓库中的 Google IP 快照 |
| `warp-vps logs` | 查看最近的服务日志 |
| `warp-vps uninstall` | 停止服务、撤销规则，并把项目文件移到备份目录 |

卸载不会删除系统依赖包。项目文件和脚本创建的 Swap 会移到 `/var/backups/warp-vps-manager/` 下的时间戳目录。

## 工作方式

- Socks5 模式只处理本机发起的出站流量。WireGuard 模式把 Google CIDR 写入主路由表，也会影响经过 VPS 转发到这些地址的流量。
- Google Cloud 客户外部 IP 从规则中排除，普通网站和其他业务流量继续直连。
- 规则快照随项目发布，不会在后台自行抓取实时 IP 列表。
- `warp-vps update` 获取仓库中的最新脚本和规则快照。
- 健康检查定时器会检查本项目的服务和分流规则。

## IP 规则来源

规则使用 Google 官方发布的两个文件：

- [Google 公网 IP 列表](https://www.gstatic.com/ipranges/goog.json)
- [Google Cloud 公网 IP 列表](https://www.gstatic.com/ipranges/cloud.json)

仓库中的快照按下面的方式生成：

```text
Google 默认服务 CIDR = goog.json - cloud.json
```

这是 IP 近似分流，不是域名识别，也不是 YouTube 或 Gemini 的专属地址清单。Google 调整地址后，需要通过项目更新取得新的快照。

## 使用边界

- 默认不做全局 WARP，也不修改现有代理程序的配置。
- Socks5 模式不能透明转发 UDP。它会阻断 Google UDP/443，支持回落的客户端会改用 TCP，不支持回落的客户端可能无法连接。
- Socks5 模式会阻断命中规则的目标 IPv6，避免客户端绕过 IPv4 分流。
- WireGuard 模式可能与已有的 WireGuard 网卡或策略路由配置冲突。
- 已有的 `redsocks.service` 保持不动，项目使用自己的 `warp-vps-redsocks.service` 和独立配置。
- 选择 Socks5 会把现有 Cloudflare WARP 客户端切换到本地代理模式。安装前已存在的 `warp-svc` 在卸载时不会被停用，客户端原来的模式也不会被猜测或恢复。
- Gemini 和 YouTube Premium 检测依赖公开网页和 Google 返回的位置。网络或响应无法解析时会显示无法确认。
- Google 将中国大陆列为 Gemini Workspace 例外地区；检测到中国大陆出口时，脚本把个人版显示为不可用，并注明 Workspace 例外。地区范围以 [Google 官方说明](https://support.google.com/gemini/answer/13575153?hl=en) 为准。
- 解锁检测用于提供信息，不决定安装、更新或重启命令是否成功。

## 排查

安装完成后先运行：

```bash
warp-vps status
warp-vps logs
```

如果安装尚未完成，请查看安装器最后一条错误，处理后重新运行安装命令，不需要先执行卸载。

## 相关项目和文档

- [Cloudflare WARP Linux 文档](https://developers.cloudflare.com/warp-client/get-started/linux/)
- [Google IP 地址范围说明](https://knowledge.workspace.google.com/admin/security/obtain-google-ip-address-ranges)
- [wgcf](https://github.com/ViRb3/wgcf)
- [redsocks](https://github.com/darkk/redsocks)

本项目使用 [MIT License](LICENSE)。
