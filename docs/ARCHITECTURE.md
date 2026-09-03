# 工作原理

## 目标分工

```text
普通公网 / Claude Code / Codex
            |
            v
      Karing TUN + 公网 DNS

100.64.0.0/10、fd7a:115c:a1e0::/48、Tailnet 私网
            |
            v
        Tailscale TUN

*.tailxxxx.ts.net
            |
            v
/etc/resolver/tailxxxx.ts.net -> 100.100.100.100
```

macOS 按“最具体路由优先”选择接口。Karing 可以持有默认公网路由，
Tailscale 同时持有 `100.64.0.0/10`、MagicDNS 和 Tailnet 设备的更具体路由。

## 为什么关闭 Tailscale 的全局 DNS 接管

本机验证中，`CorpDNS=true` 或 `RouteAll=true` 会让两个 Network Extension
重新竞争 DNS/路由。工具因此默认设置：

- `accept-dns=false`（对应 `CorpDNS=false`）；
- `accept-routes=false`（对应 `RouteAll=false`）；
- Exit Node 为空；
- 不广播本机路由。

MagicDNS 并没有被取消，而是通过 macOS `/etc/resolver/<tailnet-domain>`
做域名级分流。只有 Tailnet 域交给 `100.100.100.100`，公网 DNS 仍归 Karing。

如果确实使用 Tailnet 子网路由，可以明确传入 `--accept-routes`，并把每个
子网通过 `--extra-route CIDR` 同时加入 Karing 绕过列表。修改后必须运行
`ktnet verify --wait 60`。

## 不采用的方案

- 不使用 Tailscale Exit Node；
- 不使用 1055 SOCKS5 用户态模式；
- 不同时运行官方 Tailscale 和 Homebrew `tailscaled`；
- 不创建额外 LaunchDaemon 或周期性网络守护脚本；
- 不硬编码 `utun` 编号、Tailnet IP 或设备名称。

## 事务与回退

`configure` 的顺序是：

1. 只读预检并动态识别 Tailnet 域；
2. 在临时目录构造 Karing 候选 JSON；
3. 创建本机恢复备份；
4. 正常退出 Karing；
5. 只修改允许的 Karing 字段；
6. 设置 Tailscale 分工；
7. 安装 split-DNS resolver；
8. 重开应用并验证；
9. 即时验证失败则自动恢复刚才的备份。

管理员授权只用于写入或恢复 `/etc/resolver`。密码由 macOS `sudo` 在目标
电脑本机读取，工具不会记录密码。
