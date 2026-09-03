param(
  [switch]$KeepPersistence
)

$ErrorActionPreference = "Stop"

$TargetDir = Join-Path $env:USERPROFILE ".local\bin"
$TargetPs1 = Join-Path $TargetDir "ktnet.ps1"
$TargetCmd = Join-Path $TargetDir "ktnet.cmd"
$StateDir = Join-Path $env:USERPROFILE ".local\state\ktnet"
$DesiredPath = Join-Path $StateDir "desired-windows.json"
$RuntimeDir = Join-Path $StateDir "runtime"
$TaskNames = @("ktnet-network-guard", "ktnet-network-startup")

if (-not $KeepPersistence) {
  $existingTasks = @($TaskNames | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue })
  if ($existingTasks.Count -gt 0) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      throw "检测到 ktnet 持久计划任务。请用同一账户的管理员 PowerShell 运行卸载，或使用 .\uninstall.ps1 -KeepPersistence 仅卸载命令入口。"
    }
    foreach ($taskName in $existingTasks) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Host "已移除计划任务: $taskName"
    }
  }
  Remove-Item -LiteralPath $DesiredPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $RuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "已移除 ktnet 持久执行文件；当前 Karing/Tailscale 网络设置未回滚。"
}

if (Test-Path $TargetCmd) {
  Remove-Item -Force $TargetCmd
  Write-Host "已移除: $TargetCmd"
}
if (Test-Path $TargetPs1) {
  Remove-Item -Force $TargetPs1
  Write-Host "已移除: $TargetPs1"
}

$oldPath = [Environment]::GetEnvironmentVariable("Path", "User")
$segments = $oldPath -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($_ -ne $TargetDir) }
$newPath = $segments -join ";"
if ($newPath -ne $oldPath) {
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  Write-Host "已从用户 PATH 中移除: $TargetDir（如有会话窗口请重开终端）"
}

Write-Host "已卸载 ktnet 命令行入口。备份和 guard 日志不会被删除。"
