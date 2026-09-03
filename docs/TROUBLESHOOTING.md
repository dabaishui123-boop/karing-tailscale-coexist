# 故障排查

## 先运行

```bash
ktnet doctor
ktnet verify --wait 60
```

不要先删除应用、切换 Tailscale 发行版本或建立 SOCKS5 服务。

## Karing 已连接但公网不可用

检查 `doctor` 输出中的公网接口是否等于 Karing 接口，并确认 Karing 自己的
代理节点可用。工具不会同步订阅，因此另一台电脑必须自行导入合法订阅。

## Tailscale 显示 Starting 或 Stopped

打开官方 Tailscale app，确认已经登录。初次授权可能需要浏览器确认和
macOS Network Extension 批准。完成后再运行 `ktnet doctor`。

## MagicDNS 不能解析

```bash
scutil --dns
route -n get 100.100.100.100
```

预期应看到当前 Tailnet 域对应 `100.100.100.100`，其路由走 Tailscale
接口。如果 Tailnet 域发生变化，重新执行 `ktnet configure`。

## Tailnet 设备不在线

`verify` 只会选择当前在线设备。没有在线设备时会报告警告而非伪造成功。
普通 `ping` 不能代替 `tailscale ping`。

## 需要使用 Tailnet 子网路由

例如需要访问另一台设备发布的 `192.168.50.0/24`：

```bash
ktnet plan --accept-routes --extra-route 192.168.50.0/24
ktnet configure --accept-routes --extra-route 192.168.50.0/24
ktnet verify --wait 60
```

## 回退

```bash
ktnet backups
ktnet restore ~/.local/state/ktnet/backups/时间戳
```

恢复会正常重启 Karing，并可能再次要求本机管理员授权以恢复 resolver。

## 不要这样处理

- 不要同时启动 Homebrew `tailscaled` 和官方 Tailscale app；
- 不要把 Exit Node 当作修复公网的办法；
- 不要照搬旧 `utun` 编号或其他设备的 `100.x` 地址；
- 不要把完整 Karing 配置或 Tailscale 密钥提交到 Git。
