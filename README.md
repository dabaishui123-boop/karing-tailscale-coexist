# Karing + Tailscale 共存工具

让 macOS 上的两条网络通道长期保持清晰分工：

- Karing TUN 负责公网、Claude Code 和 Codex；
- Tailscale 只负责 Tailnet 设备、私网开发测试和 MagicDNS；
- 不使用 Exit Node，不切换到 SOCKS5 用户态方案；
- 不硬编码 `utun` 编号、设备 IP 或电脑名称；
- 所有修改先备份，失败自动回退。

## 支持范围

- macOS 12 或更高；
- Karing 官方 macOS 版；
- Tailscale 官方独立 macOS 版；
- 必须在目标 Mac 的本机终端运行 `configure`，禁止通过 SSH 修改网络。

官方安装来源：

- Tailscale: <https://tailscale.com/download/mac>
- Karing: <https://github.com/KaringX/karing/releases/latest>

仓库不会安装或同步代理订阅、Tailscale 登录身份和 SSH 密钥。

## 命令概览

| 命令 | 是否修改系统 | 用途 |
|---|---:|---|
| `ktnet doctor` | 否 | 检查应用、VPN、偏好、路由和 resolver |
| `ktnet plan` | 否 | 显示将要应用的分工 |
| `ktnet configure` | 是 | 备份、应用、重启 Karing、即时验证 |
| `ktnet configure --dry-run` | 否 | 生成候选设置但不写入 |
| `ktnet verify --wait 60` | 否 | 即时和延迟两轮端到端验证 |
| `ktnet backup` | 仅写本机备份 | 创建可恢复快照 |
| `ktnet backups` | 否 | 列出本机备份 |
| `ktnet restore <目录>` | 是 | 恢复指定快照 |
| `ktnet open-downloads` | 打开网页 | 打开两个官方安装页面 |

## 在另一台 Mac 上使用

### 1. 安装并登录两个官方应用

先安装 Karing 与官方独立版 Tailscale：

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

阅读计划后输入 `APPLY`。写入 `/etc/resolver` 时 macOS 会在本机终端要求
管理员密码；密码不会被工具保存。

### 5. 最终验证

```bash
ktnet verify --wait 60
```

如需严格验证开机恢复，再手动重启 Mac，登录后重新运行同一条命令。

## 使用额外子网路由

默认配置与本机已验证状态一致：`accept-routes=false`。如果 Tailnet 中确实
发布了额外私网，例如 `192.168.50.0/24`，应同时接受路由并让 Karing 绕过：

```bash
ktnet configure \
  --accept-routes \
  --extra-route 192.168.50.0/24
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

只卸载命令行入口，不动网络配置和备份：

```bash
./uninstall.sh
```

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，故障处理见
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)，敏感信息边界见
[SECURITY.md](SECURITY.md)。

提交前可运行：

```bash
bash tests/run.sh
bash scripts/security-audit.sh
```
