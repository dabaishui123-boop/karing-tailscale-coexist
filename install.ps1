param(
    [string]$Version = "0.2.0"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourcePs1 = Join-Path $ScriptDir "bin\ktnet.ps1"
$StateDir = Join-Path $env:USERPROFILE ".local\state\ktnet"
$TargetDir = Join-Path $env:USERPROFILE ".local\bin"
$TargetPs1 = Join-Path $TargetDir "ktnet.ps1"
$TargetCmd = Join-Path $TargetDir "ktnet.cmd"

if (-not (Test-Path $SourcePs1)) {
  throw "找不到入口文件: $SourcePs1"
}

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

Copy-Item -Path $SourcePs1 -Destination $TargetPs1 -Force

$cmdContent = @"
@echo off
setlocal
set "SCRIPT=%~dp0ktnet.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
"@

Set-Content -Path $TargetCmd -Value $cmdContent -NoNewline -Encoding ASCII

Write-Host "已安装 ktnet 命令到: $TargetDir" -ForegroundColor Green

$oldPath = [Environment]::GetEnvironmentVariable("Path", "User")
$segments = $oldPath -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($segments -notcontains $TargetDir) {
  $newPath = ($segments + $TargetDir) -join ";"
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  Write-Host "已将 $TargetDir 加入用户 PATH，需重开终端后生效。" -ForegroundColor Yellow
} else {
  Write-Host "用户 PATH 已包含: $TargetDir"
}

Write-Host "安装完成，下一步："
Write-Host "  ktnet doctor"
Write-Host "  ktnet plan"
Write-Host "  ktnet configure --dry-run"
Write-Host "  # 确认后，在管理员 PowerShell 中运行 ktnet configure"
Write-Host "当前脚本版本: $Version"
