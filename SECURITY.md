# 安全边界

此仓库只保存通用分流逻辑，不应保存任何个人网络凭据。

禁止提交：

- Karing 订阅地址、节点配置、代理服务器、密钥和令牌；
- Tailscale auth key、设备密钥、账户导出或 ACL 私有信息；
- SSH 私钥、密码、API key；
- `~/.local/state/ktnet/backups` 下的本机备份；
- 从 `~/Library/Group Containers/group.com.nebula.karing` 复制出的完整文件。

`ktnet backup` 把恢复资料保存在每台电脑自己的本机状态目录：macOS 为
`~/.local/state/ktnet/backups`，Windows 为
`%USERPROFILE%\.local\state\ktnet\backups`。该目录不在 Git 仓库内。

Windows 备份中的 `karing_setting.json` 可能包含订阅相关信息，因此只能
保留在目标电脑本机，不应复制到仓库、聊天或工单。`desired-windows.json`
和计划任务 XML 只包含路径、CIDR 与布尔偏好，不包含登录凭据。

如果仓库意外加入敏感文件，应先撤销/轮换对应密钥，再清理 Git 历史；
仅从最新提交删除文件并不能从历史中抹除它。
