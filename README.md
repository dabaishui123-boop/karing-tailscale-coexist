# Karing + Tailscale 共存工具

让 macOS 和 Windows 上的两条网络通道长期保持清晰分工：

- Karing TUN 负责公网、Claude Code 和 Codex；
- Tailscale 只负责 Tailnet 设备、私网开发测试和 MagicDNS；
- 不使用 Exit Node，不切换到 SOCKS5 用户态方案；
- 不硬编码 `utun` 编号、设备 IP 或电脑名称；
- 所有修改先备份，失败自动回退，并支持持久执行。

## 支持范围

- macOS 12 或更高；
- Windows 10/11（PowerShell）；
- Karing 官方桌面版；
- Tailscale 官方桌面版；
- 必须在目标电脑的本机终端运行 `configure`，不要通过远程会话修改网络。

Windows 端提供完整的检查、配置、持久化、验证、备份和恢复命令。
`configure` 会保留 Karing 原有绕过项，追加 Tailnet 网段，持久写入
Tailscale 偏好，并安装“登录恢复 + 每 5 分钟低侵入纠偏”任务；主动断开的
隧道不会被周期任务强制重连。详见 [Windows 使用说明](docs/WINDOWS.md)。

官方安装来源：

- Tailscale macOS: <https://tailscale.com/download/mac>
- Tailscale Windows: <https://tailscale.com/download/windows>
- Karing: <https://github.com/KaringX/karing/releases/latest>

仓库不会安装或同步代理订阅、Tailscale 登录身份和 SSH 密钥。

## 命令概览

| 命令 | 是否修改系统 | 用途 |
|---|---:|---|
| `ktnet doctor` | 否 | 检查应用、VPN、偏好、路由和 DNS 分流 |
| `ktnet plan` | 否 | 显示将要应用的分工 |
| `ktnet configure` | 是 | 备份、应用、重启 Karing、安装持久任务、即时验证 |
| `ktnet configure --dry-run` | 否 | 生成候选设置但不写入 |
| `ktnet verify --wait 60` | 否 | 即时和延迟两轮端到端验证 |
| `ktnet backup` | 仅写本机备份 | 创建可恢复快照 |
| `ktnet backups` | 否 | 列出本机备份 |
| `ktnet restore <目录>` | 是 | 恢复指定快照 |
| `ktnet open-downloads` | 打开网页 | 打开两个官方安装页面 |

## 在另一台电脑上使用

### 1. 安装并登录两个官方应用

先安装 Karing 与官方桌面版 Tailscale：

```bash
ktnet open-downloads  # 已安装命令时可用
```

在 Karing 中自行导入自己的订阅并确认单独连接时公网可用；在 Tailscale
中使用自己的账户登录。不要把订阅或 auth key 放进 Git。

### 2. 从私有 GitHub 仓库同步

推荐使用已经登录的 GitHub CLI：

```bash
gh repo clone dabaishui123-boop/karing-tailscale-coexist
cd karing-tailscale-coexist
./install.sh
```

如果 `~/.local/bin` 尚未加入 PATH，按安装器提示将它加入 `~/.zshrc`。

在 Windows 上：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

安装后使用 `%USERPROFILE%\.local\bin\ktnet.cmd doctor`，或重新打开终端后
直接运行 `ktnet doctor`。Windows 的 `configure` 和 `restore` 需要在同一
账户的管理员 PowerShell 中运行；`doctor`、`plan`、`configure --dry-run`
和 `verify` 不写网络设置。

### 3. 先检查和预演

```bash
ktnet doctor
ktnet plan
ktnet configure --dry-run
```

Tailnet 域默认从本机登录状态自动识别，所以不用复制另一台电脑的 IP、域名
或 `utun` 编号。

### 4. 应用配置

```bash
ktnet configure
```

阅读计划后输入 `APPLY`。macOS 写入 `/etc/resolver` 时会在本机终端要求
管理员密码；Windows 需要同一账户的管理员 PowerShell。密码不会被工具保存。

### 5. 最终验证

```bash
ktnet verify --wait 60
```

如需严格验证开机恢复，再手动重启目标电脑，登录后重新运行同一条命令。

## 使用额外子网路由

默认配置与本机已验证状态一致：`accept-routes=false`。如果 Tailnet 中确实
发布了额外私网，例如 `192.168.50.0/24`，应同时接受路由并让 Karing 绕过：

```text
ktnet configure --accept-routes --extra-route 192.168.50.0/24
```

可以重复使用 `--extra-route`。每次修改后运行 `ktnet verify --wait 60`。

## 更新所有电脑

每台电脑的仓库中运行：

```bash
git pull --ff-only
ktnet doctor
ktnet configure --dry-run
```

只有当规则确实有变化时才重新运行 `ktnet configure`。Git 同步的是工具，
不是各台电脑的账户、订阅或设备身份。

## 回退与卸载

查看并恢复备份：

```bash
ktnet backups
ktnet restore ~/.local/state/ktnet/backups/时间戳
```

macOS 只卸载命令行入口，不动网络配置和备份：

```bash
./uninstall.sh
```

Windows 的 `uninstall.ps1` 会移除命令入口和 ktnet 持久任务，但不回滚当前
网络设置，也不删除备份；需要恢复旧配置时先执行 `ktnet restore`。

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，故障处理见
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)，敏感信息边界见
[SECURITY.md](SECURITY.md)。

提交前可运行：

```bash
bash tests/run.sh
bash scripts/security-audit.sh
```
