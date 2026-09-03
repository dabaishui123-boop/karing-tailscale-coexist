# Windows 版使用说明

Windows 版 `ktnet` 已提供与 macOS 相同的事务边界：先预检和备份，再写入，
写入后立即做端到端验证；失败时自动恢复 Karing、Tailscale 和持久任务。

## 目标状态

- Karing TUN 负责普通公网、Claude Code 和 Codex；
- Karing 保留已有绕过项，并确保绕过 `100.64.0.0/10`、
  `fd7a:115c:a1e0::/48` 及显式指定的 Tailnet 子网；
- Tailscale 保持登录并处理 Tailnet、MagicDNS 和按需启用的子网路由；
- Tailscale 不使用 Exit Node，也不广播本机子网或出口节点；
- 登录时恢复一次目标状态，此后每 5 分钟检查偏好漂移；
- 用户主动停止的 Tailscale 或 Karing 不会被周期任务强制重连。

Windows 没有 macOS 的 `/etc/resolver`。本工具在 Windows 上保留
`tailscale set --accept-dns=true`，由 Tailscale 的 Windows DNS/NRPT 集成
提供 MagicDNS；Karing 对 Tailnet 网段的绕过用于避免两个隧道争抢流量。

## 系统要求

- Windows 10/11 64 位；
- Windows PowerShell 5.1 或 PowerShell 7；
- Karing 官方 Windows 版已经启动过一次并已导入用户自己的订阅；
- Tailscale 官方 Windows 版已经登录且处于连接状态；
- `configure` 和 `restore` 在当前登录账户的管理员 PowerShell 中运行。

工具不会保存代理订阅、节点、Tailscale auth key 或登录凭据。完整 Karing
设置只进入本机恢复备份，不进入 Git。

## 安装

普通 PowerShell 中可以安装命令入口：

```powershell
cd karing-tailscale-coexist
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

安装位置：

- `%USERPROFILE%\.local\bin\ktnet.ps1`
- `%USERPROFILE%\.local\bin\ktnet.cmd`

如果安装器修改了用户 PATH，请关闭并重新打开 PowerShell。

## 第一次配置

先做只读检查和预演：

```powershell
ktnet doctor
ktnet plan
ktnet configure --dry-run
```

确认预演内容后，用“以管理员身份运行”的 PowerShell，在同一 Windows
账户中执行：

```powershell
ktnet configure
```

阅读计划后输入 `APPLY`。执行过程会：

1. 自动定位官方客户端和 `karing_setting.json`；
2. 构建并解析候选 Karing JSON；
3. 创建带毫秒时间戳的本机恢复快照；
4. 在备份完成后停止 Karing UI 进程，使设置文件进入可安全替换状态；
5. 原子写入 Karing 分流字段，并保留原有绕过项；
6. 持久写入 Tailscale DNS、子网和 Exit Node 偏好；
7. 保存无凭据的目标状态，安装登录任务和周期守护任务；
8. 重开 Karing，验证公网路由、HTTPS、OpenAI、Anthropic、Tailnet 和
   MagicDNS；
9. 任一关键检查失败时自动回到第 3 步的快照。

Karing 当前会把普通窗口关闭事件转换为“隐藏到托盘”，没有可用于此事务的
官方退出 CLI。输入 `APPLY` 同时表示允许工具在备份完成后结束 Karing 的
UI 进程并立即重开；只限定进程名 `Karing`，不会停止 Tailscale，也不会使用
模糊进程匹配。

配置成功后再做一分钟延迟复查：

```powershell
ktnet verify --wait 60
```

## Karing 设置文件未自动识别

官方安装器当前把用户数据放在用户 AppData 下，工具也会检查便携版目录。
如果仍未识别，可显式指定：

```powershell
ktnet configure --dry-run `
  --karing-settings "$env:APPDATA\Karing\karing_setting.json"
```

也可以设置当前终端环境变量：

```powershell
$env:KTNET_KARING_SETTINGS = "$env:APPDATA\Karing\karing_setting.json"
ktnet doctor
```

## 使用额外子网路由

默认不接受 Tailnet 广播的额外子网。确实需要访问其他设备后面的局域网时：

```powershell
ktnet configure --accept-routes `
  --extra-route 192.168.50.0/24
```

启用 `--accept-routes` 后，工具还会从当前 Tailscale 状态中发现非主机
`AllowedIPs` 并加入 Karing 绕过列表。建议仍显式传入业务必需的 CIDR，
这样即使配置时对应路由器离线，持久目标也不会遗漏。

## 备份和回滚

手动创建和列出快照：

```powershell
ktnet backup
ktnet backups
```

备份位于：

```text
%USERPROFILE%\.local\state\ktnet\backups\时间戳
```

每份版本 2 快照包含：

- 完整 `karing_setting.json`；
- 仅含安全偏好的 Tailscale 快照；
- ktnet 目标状态和运行脚本的“存在/不存在”状态；
- 两个 ktnet 计划任务的 XML 或“原先不存在”标记；
- 不含订阅内容的恢复清单，以及每个备份文件的 SHA-256 校验值。

恢复指定快照须使用管理员 PowerShell：

```powershell
ktnet restore "$env:USERPROFILE\.local\state\ktnet\backups\20260903-120000-000"
```

恢复前会先校验快照完整性，再创建一份 `pre-restore` 保护快照。恢复后若
公网不可达，工具会自动恢复这份保护快照。

## 持久任务的边界

`ktnet-network-startup` 在当前用户登录时运行一次：修复已批准的持久字段，
并按目标设置启动 Karing。

`ktnet-network-guard` 每 5 分钟检查一次：

- Tailscale 原本处于 `Running` 且 `WantRunning=true` 时，才修复其偏好；
- Tailscale 被主动停止时只记日志，不执行 `tailscale up`；
- Karing 的 `tun.enable=false` 被视为主动断开，不会改回；
- Karing 正在运行时发现文件漂移，只记录并延后到下次登录，避免后台突然
  重启代理；
- Karing 未运行且 TUN 仍标记为启用时，才原子修复持久文件。

守护日志：

```text
%USERPROFILE%\.local\state\ktnet\guard.log
```

日志超过 1 MiB 时轮换为 `guard.log.1`。

## 卸载

管理员 PowerShell 中运行：

```powershell
.\uninstall.ps1
```

默认移除命令入口、两个计划任务、目标状态和运行副本，但不改变当前
Karing/Tailscale 网络设置，也不删除备份和日志。需要恢复旧网络时，应先
运行 `ktnet restore`，再卸载。

如果只想移除命令入口、明确保留持久任务：

```powershell
.\uninstall.ps1 -KeepPersistence
```

## 验证清单

`ktnet verify --wait 60` 同时验证：

- Tailscale `BackendState=Running`、`Self.Online=true`；
- `accept-dns=true`、子网接受状态符合目标、Exit Node 为空；
- Karing 持久字段和全部必需绕过段仍存在；
- 公网目标路由进入 Karing，`100.100.100.100` 和在线 Peer 进入 Tailscale；
- Apple 公网 HTTPS、OpenAI API TLS、Anthropic API TLS 可达；
- 至少一台在线设备可 `tailscale ping`，且 MagicDNS 名称可解析。

如果当前没有在线 Peer，工具会明确警告并跳过 Peer 检查；这不等于已完成
跨设备验证，待另一台设备上线后应再次运行 `verify`。
