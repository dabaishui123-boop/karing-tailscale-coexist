param(
  [Parameter(Position = 0)]
  [string]$Command = "help",
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Options = @()
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$VERSION = "0.2.0"
$USER_ROOT = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }
$STATE_ROOT = if ($env:KTNET_STATE_ROOT) { $env:KTNET_STATE_ROOT } else { Join-Path $USER_ROOT ".local\state\ktnet" }
$BACKUP_ROOT = Join-Path $STATE_ROOT "backups"
$DESIRED_PATH = Join-Path $STATE_ROOT "desired-windows.json"
$RUNTIME_DIR = Join-Path $STATE_ROOT "runtime"
$RUNTIME_SCRIPT = Join-Path $RUNTIME_DIR "ktnet.ps1"
$GUARD_LOG = Join-Path $STATE_ROOT "guard.log"
$GUARD_TASK = "ktnet-network-guard"
$STARTUP_TASK = "ktnet-network-startup"
$TSPATH = ""
$KARING_PATH = ""
$KARING_SETTINGS = ""
$TAILNET_DOMAIN = ""
$WAIT_SECONDS = 0
$EXTRA_ROUTES = @()
$ACCEPT_ROUTES = $false
$AUTO_YES = $false
$DRY_RUN = $false
$STARTUP_MODE = $false
$CLI_ARGS = @($Options)

function Say { param([string]$Message = ""); Write-Output $Message }
function Info { param([string]$Message); Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Pass { param([string]$Message); Write-Host "[PASS]  $Message" -ForegroundColor Green }
function Warn { param([string]$Message); Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Fail { param([string]$Message); Write-Host "[FAIL]  $Message" -ForegroundColor Red }
function Die { param([string]$Message); Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

function Assert-Windows {
  if ($env:OS -ne "Windows_NT") { Die "此入口只支持 Windows 10/11" }
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-JsonFile {
  param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $json = $Object | ConvertTo-Json -Depth 100
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Set-ObjectProperty {
  param($Object, [string]$Name, $Value)
  if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
  else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Resolve-KtPaths {
  $script:TSPATH = ""
  $script:KARING_PATH = ""

  $tsCmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  $tsCandidates = @()
  if ($tsCmd) { $tsCandidates += $tsCmd.Path }
  if (${env:ProgramFiles}) { $tsCandidates += (Join-Path ${env:ProgramFiles} "Tailscale\tailscale.exe") }
  if (${env:ProgramFiles(x86)}) { $tsCandidates += (Join-Path ${env:ProgramFiles(x86)} "Tailscale\tailscale.exe") }
  foreach ($path in $tsCandidates) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { $script:TSPATH = $path; break }
  }

  $runningKaring = Get-Process -Name Karing -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($runningKaring) {
    try { if ($runningKaring.Path) { $script:KARING_PATH = $runningKaring.Path } } catch { Write-Verbose "无法读取 Karing 进程路径" }
  }
  $karingCandidates = @()
  if ($env:KTNET_KARING_APP) { $karingCandidates += $env:KTNET_KARING_APP }
  if (${env:ProgramFiles}) { $karingCandidates += (Join-Path ${env:ProgramFiles} "Karing\Karing.exe") }
  if (${env:ProgramFiles(x86)}) { $karingCandidates += (Join-Path ${env:ProgramFiles(x86)} "Karing\Karing.exe") }
  if ($env:LOCALAPPDATA) { $karingCandidates += (Join-Path $env:LOCALAPPDATA "Programs\Karing\Karing.exe") }
  foreach ($path in $karingCandidates) {
    if (-not $script:KARING_PATH -and $path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
      $script:KARING_PATH = $path
      break
    }
  }
}

function Resolve-KaringSettings {
  param([string]$Override = "")
  if ($Override) {
    if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) { Die "找不到指定的 Karing 设置文件: $Override" }
    $script:KARING_SETTINGS = (Resolve-Path -LiteralPath $Override).Path
    return $script:KARING_SETTINGS
  }
  if ($env:KTNET_KARING_SETTINGS -and (Test-Path -LiteralPath $env:KTNET_KARING_SETTINGS -PathType Leaf)) {
    $script:KARING_SETTINGS = (Resolve-Path -LiteralPath $env:KTNET_KARING_SETTINGS).Path
    return $script:KARING_SETTINGS
  }

  $candidates = @()
  foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
    if (-not $root) { continue }
    foreach ($folder in @("Karing", "karing", "com.nebula.karing")) {
      $candidates += (Join-Path (Join-Path $root $folder) "karing_setting.json")
    }
  }
  if ($script:KARING_PATH) {
    $appDir = Split-Path -Parent $script:KARING_PATH
    $candidates += (Join-Path $appDir "data\karing_setting.json")
    $candidates += (Join-Path $appDir "karing_setting.json")
  }
  $existing = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object LastWriteTime -Descending)
  if ($existing.Count -gt 0) { $script:KARING_SETTINGS = $existing[0].FullName }
  return $script:KARING_SETTINGS
}

function Invoke-Tailscale {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$TsArgs)
  if (-not $script:TSPATH) { throw "找不到 Tailscale CLI" }
  $output = & $script:TSPATH @TsArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "tailscale $($TsArgs -join ' ') 失败: $($output -join ' ')" }
  return $output
}

function Get-TailscaleStatus {
  if (-not $script:TSPATH) { return $null }
  try { return ((Invoke-Tailscale status --json) -join [Environment]::NewLine | ConvertFrom-Json) } catch { return $null }
}

function Get-TailscalePrefs {
  if (-not $script:TSPATH) { return $null }
  try { return ((Invoke-Tailscale debug prefs) -join [Environment]::NewLine | ConvertFrom-Json) } catch { return $null }
}

function Assert-TailscaleSetCapabilities {
  $help = (Invoke-Tailscale set --help) -join [Environment]::NewLine
  foreach ($flag in @("--accept-dns", "--accept-routes", "--exit-node", "--advertise-exit-node", "--advertise-routes")) {
    if ($help -notmatch [Regex]::Escape($flag)) { throw "当前 Tailscale 版本不支持必需参数: $flag" }
  }
}

function Detect-TailnetDomain {
  $status = Get-TailscaleStatus
  if (-not $status -or -not $status.Self -or -not $status.Self.DNSName) { return "" }
  $dnsName = ([string]$status.Self.DNSName).Trim().TrimEnd('.')
  $labels = $dnsName.Split('.')
  if ($labels.Count -ge 3 -and $dnsName.EndsWith('.ts.net')) { return ($labels[1..($labels.Count - 1)] -join '.') }
  return ""
}

function Test-Cidr {
  param([string]$Cidr)
  if ($Cidr -notmatch '^(.+)/(\d{1,3})$') { return $false }
  $ip = $null
  if (-not [Net.IPAddress]::TryParse($matches[1], [ref]$ip)) { return $false }
  $prefix = [int]$matches[2]
  if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return ($prefix -ge 0 -and $prefix -le 32) }
  return ($prefix -ge 0 -and $prefix -le 128)
}

function Parse-Options {
  param([string[]]$Arguments)
  $idx = 0
  while ($idx -lt $Arguments.Count) {
    switch ($Arguments[$idx]) {
      "--tailnet-domain" {
        if ($idx + 1 -ge $Arguments.Count) { Die "--tailnet-domain 需要参数" }
        $script:TAILNET_DOMAIN = $Arguments[$idx + 1].Trim().TrimEnd('.')
        if ($script:TAILNET_DOMAIN -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.ts\.net$') { Die "Tailnet 域格式不正确" }
        $idx += 2
      }
      "--extra-route" {
        if ($idx + 1 -ge $Arguments.Count) { Die "--extra-route 需要 CIDR" }
        if (-not (Test-Cidr $Arguments[$idx + 1])) { Die "CIDR 格式不正确: $($Arguments[$idx + 1])" }
        $script:EXTRA_ROUTES += $Arguments[$idx + 1]
        $idx += 2
      }
      "--karing-settings" {
        if ($idx + 1 -ge $Arguments.Count) { Die "--karing-settings 需要文件路径" }
        $script:KARING_SETTINGS = $Arguments[$idx + 1]
        $idx += 2
      }
      "--accept-routes" { $script:ACCEPT_ROUTES = $true; $idx++ }
      "--yes" { $script:AUTO_YES = $true; $idx++ }
      "--dry-run" { $script:DRY_RUN = $true; $idx++ }
      "--startup" { $script:STARTUP_MODE = $true; $idx++ }
      "--wait" {
        if ($idx + 1 -ge $Arguments.Count -or $Arguments[$idx + 1] -notmatch '^\d+$') { Die "--wait 需要 0-300 的整数秒数" }
        $script:WAIT_SECONDS = [int]$Arguments[$idx + 1]
        if ($script:WAIT_SECONDS -gt 300) { Die "--wait 最大为 300 秒" }
        $idx += 2
      }
      default { Die "未知参数: $($Arguments[$idx])" }
    }
  }
}

function Get-AdvertisedSubnetRoutes {
  if (-not $script:ACCEPT_ROUTES) { return @() }
  $status = Get-TailscaleStatus
  if (-not $status -or -not $status.Peer) { return @() }
  $routes = New-Object System.Collections.Generic.List[string]
  foreach ($property in $status.Peer.PSObject.Properties) {
    foreach ($cidr in @($property.Value.AllowedIPs)) {
      if (-not $cidr -or $cidr -in @("0.0.0.0/0", "::/0")) { continue }
      if ($cidr -match '/32$' -or $cidr -match '/128$') { continue }
      if ($cidr -eq "100.64.0.0/10" -or $cidr -eq "fd7a:115c:a1e0::/48") { continue }
      if ((Test-Cidr $cidr) -and -not $routes.Contains([string]$cidr)) { $routes.Add([string]$cidr) }
    }
  }
  return @($routes)
}

function Get-RequiredRoutes {
  $routes = New-Object System.Collections.Generic.List[string]
  foreach ($route in @("100.64.0.0/10", "fd7a:115c:a1e0::/48") + $script:EXTRA_ROUTES + (Get-AdvertisedSubnetRoutes)) {
    if ($route -and -not $routes.Contains([string]$route)) { $routes.Add([string]$route) }
  }
  return @($routes)
}

function Get-KaringConfig {
  param([string]$Path = $script:KARING_SETTINGS)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到 Karing 设置文件" }
  $config = Read-JsonFile $Path
  if (-not $config.tun) { Set-ObjectProperty $config "tun" ([PSCustomObject]@{}) }
  return $config
}

function Set-KaringDesiredFields {
  param($Config, [string[]]$RequiredRoutes)
  Set-ObjectProperty $Config.tun "enable" $true
  Set-ObjectProperty $Config.tun "auto_route" $true
  Set-ObjectProperty $Config.tun "hijack_dns" $true
  Set-ObjectProperty $Config "auto_connect_after_launch" $true
  Set-ObjectProperty $Config "auto_connect_at_boot" $true
  Set-ObjectProperty $Config "private_direct" $true
  $merged = New-Object System.Collections.Generic.List[string]
  foreach ($route in @($Config.tun.route_exclude_address) + $RequiredRoutes) {
    if ($route -and -not $merged.Contains([string]$route)) { $merged.Add([string]$route) }
  }
  Set-ObjectProperty $Config.tun "route_exclude_address" @($merged)
  return $Config
}

function Test-KaringDesiredFields {
  param($Config, [string[]]$RequiredRoutes)
  if (-not $Config.tun -or $Config.tun.enable -ne $true -or $Config.tun.auto_route -ne $true -or $Config.tun.hijack_dns -ne $true) { return $false }
  if ($Config.auto_connect_after_launch -ne $true -or $Config.auto_connect_at_boot -ne $true -or $Config.private_direct -ne $true) { return $false }
  $actual = @($Config.tun.route_exclude_address)
  foreach ($route in $RequiredRoutes) { if ($actual -notcontains $route) { return $false } }
  return $true
}

function Write-KaringConfigAtomic {
  param($Config, [string]$Path)
  $candidate = "$Path.ktnet-new"
  Write-JsonFile $Config $candidate
  $null = Read-JsonFile $candidate
  Move-Item -LiteralPath $candidate -Destination $Path -Force
}

function Get-SafeTailscaleSnapshot {
  $prefs = Get-TailscalePrefs
  if (-not $prefs) { return $null }
  $advertised = @($prefs.AdvertiseRoutes | ForEach-Object { [string]$_ })
  $exitRoutes = @("0.0.0.0/0", "::/0")
  return [ordered]@{
    wantRunning = [bool]$prefs.WantRunning
    acceptDns = [bool]$prefs.CorpDNS
    acceptRoutes = [bool]$prefs.RouteAll
    exitNodeIp = if ($prefs.ExitNodeIP) { [string]$prefs.ExitNodeIP } else { "" }
    advertiseExitNode = (@($advertised | Where-Object { $_ -in $exitRoutes }).Count -gt 0)
    advertiseRoutes = @($advertised | Where-Object { $_ -notin $exitRoutes })
  }
}

function Set-TailscaleDesired {
  param([bool]$AcceptRoutes)
  $value = $AcceptRoutes.ToString().ToLowerInvariant()
  $null = Invoke-Tailscale set --accept-dns=true --accept-routes=$value --exit-node= --advertise-exit-node=false --advertise-routes=
}

function Restore-TailscaleSnapshot {
  param($Snapshot)
  if (-not $Snapshot) { return }
  $routes = @($Snapshot.advertiseRoutes) -join ','
  $dns = ([bool]$Snapshot.acceptDns).ToString().ToLowerInvariant()
  $accept = ([bool]$Snapshot.acceptRoutes).ToString().ToLowerInvariant()
  $advertiseExit = ([bool]$Snapshot.advertiseExitNode).ToString().ToLowerInvariant()
  $exitNode = [string]$Snapshot.exitNodeIp
  $null = Invoke-Tailscale set --accept-dns=$dns --accept-routes=$accept --exit-node=$exitNode --advertise-exit-node=$advertiseExit --advertise-routes=$routes
}

function Get-TaskFileName {
  param([string]$TaskName)
  return ($TaskName -replace '[^A-Za-z0-9_.-]', '_') + ".xml"
}

function New-Backup {
  param([string]$Reason = "manual")
  Resolve-KtPaths
  if (-not $script:KARING_SETTINGS) { $null = Resolve-KaringSettings }
  if (-not $script:KARING_SETTINGS) { throw "找不到 Karing 设置文件，无法创建恢复备份" }
  New-Item -ItemType Directory -Force -Path $BACKUP_ROOT | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $backupDir = Join-Path $BACKUP_ROOT $stamp
  New-Item -ItemType Directory -Path $backupDir | Out-Null
  Copy-Item -LiteralPath $script:KARING_SETTINGS -Destination (Join-Path $backupDir "karing_setting.json")

  $tsSnapshot = Get-SafeTailscaleSnapshot
  if ($tsSnapshot) { Write-JsonFile $tsSnapshot (Join-Path $backupDir "tailscale-safe.json") }
  if (Test-Path -LiteralPath $DESIRED_PATH) { Copy-Item -LiteralPath $DESIRED_PATH -Destination (Join-Path $backupDir "desired-windows.json") }
  else { New-Item -ItemType File -Path (Join-Path $backupDir "desired.absent") | Out-Null }
  if (Test-Path -LiteralPath $RUNTIME_SCRIPT) { Copy-Item -LiteralPath $RUNTIME_SCRIPT -Destination (Join-Path $backupDir "runtime-ktnet.ps1") }
  else { New-Item -ItemType File -Path (Join-Path $backupDir "runtime.absent") | Out-Null }

  foreach ($taskName in @($GUARD_TASK, $STARTUP_TASK)) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $taskFile = Join-Path $backupDir (Get-TaskFileName $taskName)
    if ($task) { Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath $taskFile -Encoding Unicode }
    else { New-Item -ItemType File -Path ($taskFile + ".absent") | Out-Null }
  }

  $manifest = [ordered]@{
    backupVersion = 2
    platform = "windows"
    createdAt = (Get-Date).ToString("o")
    reason = $Reason
    karingSettingsPath = $script:KARING_SETTINGS
    karingAppPath = $script:KARING_PATH
    karingWasRunning = [bool](Get-Process -Name Karing -ErrorAction SilentlyContinue)
    tailnetDomain = Detect-TailnetDomain
    fileHashes = [ordered]@{}
  }
  foreach ($file in Get-ChildItem -LiteralPath $backupDir -File) {
    $manifest.fileHashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  Write-JsonFile $manifest (Join-Path $backupDir "manifest.json")
  return $backupDir
}

function Assert-BackupIntegrity {
  param([string]$BackupDir, $Manifest)
  if (-not $Manifest.fileHashes) { throw "备份缺少完整性清单" }
  foreach ($property in $Manifest.fileHashes.PSObject.Properties) {
    $file = Join-Path $BackupDir $property.Name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "备份文件缺失: $($property.Name)" }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne ([string]$property.Value).ToLowerInvariant()) { throw "备份文件校验失败: $($property.Name)" }
  }
}

function Stop-KaringForTransaction {
  $processes = @(Get-Process -Name Karing -ErrorAction SilentlyContinue)
  if ($processes.Count -eq 0) { return $false }
  # Karing intercepts WM_CLOSE and hides to the tray, so CloseMainWindow cannot
  # produce a reliable quiescent settings file. APPLY authorizes this bounded
  # UI-process stop after a recovery snapshot has been completed.
  $processes | Stop-Process -Force
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline -and (Get-Process -Name Karing -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 250 }
  if (Get-Process -Name Karing -ErrorAction SilentlyContinue) {
    throw "无法停止 Karing UI 进程，未写入设置"
  }
  return $true
}

function Start-Karing {
  param([string]$Path = $script:KARING_PATH)
  if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Get-Process -Name Karing -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $Path
  }
}

function Install-PersistenceTasks {
  New-Item -ItemType Directory -Force -Path $RUNTIME_DIR | Out-Null
  Copy-Item -LiteralPath $PSCommandPath -Destination $RUNTIME_SCRIPT -Force
  $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew

  $startupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$RUNTIME_SCRIPT`" guard --startup"
  $startupTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  Register-ScheduledTask -TaskName $STARTUP_TASK -Action $startupAction -Trigger $startupTrigger -Principal $principal -Settings $settings -Description "Restore the approved Karing and Tailscale split at user logon." -Force | Out-Null

  $guardAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$RUNTIME_SCRIPT`" guard"
  $guardTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  Register-ScheduledTask -TaskName $GUARD_TASK -Action $guardAction -Trigger $guardTrigger -Principal $principal -Settings $settings -Description "Audit and repair approved split preferences without reconnecting stopped tunnels." -Force | Out-Null
}

function Restore-TaskSnapshot {
  param([string]$BackupDir, [string]$TaskName)
  $taskFile = Join-Path $BackupDir (Get-TaskFileName $TaskName)
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $taskFile -PathType Leaf) {
    $xml = Get-Content -LiteralPath $taskFile -Raw -Encoding Unicode
    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
  }
}

function Restore-BackupInternal {
  param([string]$BackupDir)
  $manifestPath = Join-Path $BackupDir "manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "无效备份：缺少 manifest.json" }
  $manifest = Read-JsonFile $manifestPath
  if ($manifest.backupVersion -ne 2 -or $manifest.platform -ne "windows") { throw "不支持的 Windows 备份版本" }
  Assert-BackupIntegrity $BackupDir $manifest
  $savedKaring = Join-Path $BackupDir "karing_setting.json"
  if (-not (Test-Path -LiteralPath $savedKaring -PathType Leaf)) { throw "备份缺少 Karing 设置" }
  $settingsPath = [string]$manifest.karingSettingsPath
  if (-not $settingsPath) { throw "备份缺少 Karing 设置路径" }
  if ((Split-Path -Leaf $settingsPath) -ne "karing_setting.json") { throw "备份内 Karing 设置路径不安全" }

  $wasRunningNow = Stop-KaringForTransaction
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
  Write-KaringConfigAtomic (Read-JsonFile $savedKaring) $settingsPath
  $tsFile = Join-Path $BackupDir "tailscale-safe.json"
  if (Test-Path -LiteralPath $tsFile) { Restore-TailscaleSnapshot (Read-JsonFile $tsFile) }

  foreach ($taskName in @($GUARD_TASK, $STARTUP_TASK)) { Restore-TaskSnapshot $BackupDir $taskName }
  if (Test-Path -LiteralPath (Join-Path $BackupDir "desired-windows.json")) {
    Copy-Item -LiteralPath (Join-Path $BackupDir "desired-windows.json") -Destination $DESIRED_PATH -Force
  } else { Remove-Item -LiteralPath $DESIRED_PATH -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath (Join-Path $BackupDir "runtime-ktnet.ps1")) {
    New-Item -ItemType Directory -Force -Path $RUNTIME_DIR | Out-Null
    Copy-Item -LiteralPath (Join-Path $BackupDir "runtime-ktnet.ps1") -Destination $RUNTIME_SCRIPT -Force
  } else { Remove-Item -LiteralPath $RUNTIME_SCRIPT -Force -ErrorAction SilentlyContinue }

  $script:KARING_PATH = [string]$manifest.karingAppPath
  if ($wasRunningNow -or [bool]$manifest.karingWasRunning) { Start-Karing $script:KARING_PATH }
}

function Get-TailscaleInterfaceIndex {
  try {
    $ip = ((Invoke-Tailscale ip -4) | Select-Object -First 1).Trim()
    if ($ip) { return (Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceIndex -First 1) }
  } catch { Write-Verbose "无法通过 Tailscale IP 识别接口" }
  return (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like "*Tailscale*" -or $_.Name -like "*Tailscale*" } | Select-Object -ExpandProperty ifIndex -First 1)
}

function Get-KaringInterfaceIndex {
  if ($script:KARING_SETTINGS -and (Test-Path -LiteralPath $script:KARING_SETTINGS)) {
    try {
      $config = Get-KaringConfig
      $configuredIp = ([string]$config.tun.ipv4_address).Split('/')[0]
      if ($configuredIp) {
        $index = Get-NetIPAddress -IPAddress $configuredIp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceIndex -First 1
        if ($index) { return $index }
      }
    } catch { Write-Verbose "无法从 Karing 设置识别 TUN 地址" }
  }
  foreach ($candidate in @("10.20.0.1", "10.20.0.2")) {
    $index = Get-NetIPAddress -IPAddress $candidate -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceIndex -First 1
    if ($index) { return $index }
  }
  $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.InterfaceDescription -match 'Karing|sing-box|Wintun' -or $_.Name -match 'Karing|sing-box'
  } | Select-Object -First 1
  if ($adapter) { return $adapter.ifIndex }
  return $null
}

function Get-BestRouteInterfaceIndex {
  param([string]$Destination)
  try { return (Find-NetRoute -RemoteIPAddress $Destination -ErrorAction Stop | Select-Object -ExpandProperty InterfaceIndex -First 1) } catch { return $null }
}

function Test-HttpsReachable {
  param([string]$Uri, [int[]]$AllowedStatus)
  try {
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Method Head -TimeoutSec 15
    return ($AllowedStatus -contains [int]$response.StatusCode)
  } catch {
    try { return ($AllowedStatus -contains [int]$_.Exception.Response.StatusCode) } catch { return $false }
  }
}

function Get-OnlinePeer {
  param($Status)
  if (-not $Status -or -not $Status.Peer) { return $null }
  return ($Status.Peer.PSObject.Properties | Where-Object { $_.Value.Online -eq $true } | Select-Object -ExpandProperty Value -First 1)
}

function Test-DesiredState {
  param([bool]$Quiet = $false)
  $ok = $true
  Resolve-KtPaths
  $desired = if (Test-Path -LiteralPath $DESIRED_PATH) { Read-JsonFile $DESIRED_PATH } else { $null }
  if ($desired) { $script:KARING_SETTINGS = [string]$desired.karingSettingsPath }
  elseif (-not $script:KARING_SETTINGS) { $null = Resolve-KaringSettings }
  $status = Get-TailscaleStatus
  $prefs = Get-TailscalePrefs

  if ($status -and $status.BackendState -eq "Running" -and $status.Self.Online -eq $true) {
    if (-not $Quiet) { Pass "Tailscale Running / Online" }
  } else { if (-not $Quiet) { Fail "Tailscale 未正常运行" }; $ok = $false }
  if ($prefs) {
    $expectedAccept = if ($desired) { [bool]$desired.acceptRoutes } else { $script:ACCEPT_ROUTES }
    $advertised = @($prefs.AdvertiseRoutes | Where-Object { $_ })
    if ($prefs.WantRunning -ne $true -or $prefs.CorpDNS -ne $true -or [bool]$prefs.RouteAll -ne $expectedAccept -or $prefs.ExitNodeID -or $prefs.ExitNodeIP -or $advertised.Count -gt 0) {
      if (-not $Quiet) { Fail "Tailscale 运行、DNS、路由、Exit Node 或广播偏好与目标不一致" }
      $ok = $false
    } elseif (-not $Quiet) { Pass "Tailscale 保留 MagicDNS、未使用 Exit Node" }
  } else { if (-not $Quiet) { Fail "无法读取 Tailscale 偏好" }; $ok = $false }

  if ($desired -and $script:KARING_SETTINGS -and (Test-Path -LiteralPath $script:KARING_SETTINGS)) {
    $config = Get-KaringConfig
    if (Test-KaringDesiredFields $config @($desired.requiredRoutes)) { if (-not $Quiet) { Pass "Karing 持久设置与绕过网段正确" } }
    else { if (-not $Quiet) { Fail "Karing 持久设置发生漂移" }; $ok = $false }
  }

  $publicIf = Get-BestRouteInterfaceIndex "8.8.8.8"
  $karingIf = Get-KaringInterfaceIndex
  if ($publicIf -and $karingIf -and $publicIf -eq $karingIf) { if (-not $Quiet) { Pass "公网路由 -> Karing 接口 ($publicIf)" } }
  else { if (-not $Quiet) { Fail "公网路由接口($publicIf) 与 Karing 接口($karingIf)不一致" }; $ok = $false }
  $magicIf = Get-BestRouteInterfaceIndex "100.100.100.100"
  $tsIf = Get-TailscaleInterfaceIndex
  if ($magicIf -and $tsIf -and $magicIf -eq $tsIf) { if (-not $Quiet) { Pass "MagicDNS 路由 -> Tailscale 接口 ($magicIf)" } }
  else { if (-not $Quiet) { Fail "MagicDNS 路由未进入 Tailscale" }; $ok = $false }

  if (Test-HttpsReachable "https://www.apple.com" @(200, 204, 301, 302)) { if (-not $Quiet) { Pass "公网 HTTPS 正常" } }
  else { if (-not $Quiet) { Fail "公网 HTTPS 不可达" }; $ok = $false }
  if (Test-HttpsReachable "https://api.openai.com/v1/models" @(200, 400, 401, 403, 404, 405)) { if (-not $Quiet) { Pass "OpenAI API TLS 可达" } }
  else { if (-not $Quiet) { Fail "OpenAI API TLS 不可达" }; $ok = $false }
  if (Test-HttpsReachable "https://api.anthropic.com" @(200, 400, 401, 403, 404, 405)) { if (-not $Quiet) { Pass "Anthropic API TLS 可达" } }
  else { if (-not $Quiet) { Fail "Anthropic API TLS 不可达" }; $ok = $false }

  $peer = Get-OnlinePeer $status
  if ($peer) {
    $peerIp = @($peer.TailscaleIPs | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
    if ($peerIp.Count -gt 0) {
      $peerIf = Get-BestRouteInterfaceIndex ([string]$peerIp[0])
      if ($peerIf -eq $tsIf) { if (-not $Quiet) { Pass "在线 Tailnet 设备路由 -> Tailscale" } }
      else { if (-not $Quiet) { Fail "在线 Tailnet 设备路由未进入 Tailscale" }; $ok = $false }
      try {
        $null = Invoke-Tailscale ping --timeout=8s ([string]$peerIp[0])
        if (-not $Quiet) { Pass "tailscale ping 在线设备成功" }
      } catch { if (-not $Quiet) { Fail "tailscale ping 在线设备失败" }; $ok = $false }
    }
    if ($peer.DNSName) {
      try {
        $null = Resolve-DnsName -Name ([string]$peer.DNSName).TrimEnd('.') -Type A -ErrorAction Stop
        if (-not $Quiet) { Pass "MagicDNS 解析成功" }
      } catch { if (-not $Quiet) { Fail "MagicDNS 解析失败" }; $ok = $false }
    }
  } elseif (-not $Quiet) { Warn "当前没有在线 Tailnet 设备，跳过 peer 验证" }
  return $ok
}

function Add-GuardLog {
  param([string]$Message)
  New-Item -ItemType Directory -Force -Path $STATE_ROOT | Out-Null
  if ((Test-Path -LiteralPath $GUARD_LOG) -and (Get-Item -LiteralPath $GUARD_LOG).Length -gt 1048576) {
    Move-Item -LiteralPath $GUARD_LOG -Destination "$GUARD_LOG.1" -Force
  }
  Add-Content -LiteralPath $GUARD_LOG -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}

function Cmd-Guard {
  param([string[]]$Arguments)
  Parse-Options $Arguments
  Assert-Windows
  if (-not (Test-Path -LiteralPath $DESIRED_PATH)) { Add-GuardLog "skip: no desired state"; return }
  try {
    $desired = Read-JsonFile $DESIRED_PATH
    Resolve-KtPaths
    $script:KARING_SETTINGS = [string]$desired.karingSettingsPath
    $status = Get-TailscaleStatus
    $prefs = Get-TailscalePrefs
    if ($status -and $status.BackendState -eq "Running" -and $prefs -and $prefs.WantRunning -eq $true) {
      $advertised = @($prefs.AdvertiseRoutes | Where-Object { $_ })
      $needsTsRepair = ($prefs.CorpDNS -ne $true -or [bool]$prefs.RouteAll -ne [bool]$desired.acceptRoutes -or $prefs.ExitNodeID -or $prefs.ExitNodeIP -or $advertised.Count -gt 0)
      if ($needsTsRepair) { Set-TailscaleDesired ([bool]$desired.acceptRoutes); Add-GuardLog "repaired Tailscale preferences" }
    } else { Add-GuardLog "skip Tailscale repair: tunnel intentionally stopped or unavailable" }

    if (Test-Path -LiteralPath $script:KARING_SETTINGS) {
      $config = Get-KaringConfig
      if ($config.tun.enable -eq $true -and -not (Test-KaringDesiredFields $config @($desired.requiredRoutes))) {
        if (Get-Process -Name Karing -ErrorAction SilentlyContinue) { Add-GuardLog "detected Karing drift; deferred until next startup" }
        else {
          $config = Set-KaringDesiredFields $config @($desired.requiredRoutes)
          Write-KaringConfigAtomic $config $script:KARING_SETTINGS
          Add-GuardLog "repaired Karing persisted settings"
        }
      } elseif ($config.tun.enable -ne $true) { Add-GuardLog "skip Karing repair: tunnel intentionally disabled" }
    }
    if ($script:STARTUP_MODE -and -not (Get-Process -Name Karing -ErrorAction SilentlyContinue)) {
      Start-Karing ([string]$desired.karingAppPath)
      Add-GuardLog "started Karing at logon"
    }
  } catch { Add-GuardLog "error: $($_.Exception.Message)"; exit 1 }
}

function Show-Plan {
  param([string[]]$Routes)
  Say "准备应用以下 Windows 持久分工："
  Say "  Karing: TUN、自动路由、DNS 劫持、开机/启动后自动连接、private_direct"
  Say "  Karing 保留原绕过项，并确保加入: $($Routes -join ', ')"
  Say "  Tailscale: accept-dns=true（MagicDNS）、accept-routes=$($script:ACCEPT_ROUTES.ToString().ToLowerInvariant())"
  Say "  Tailscale: 清空 Exit Node，不广播本机子网或出口节点"
  Say "  持久化: 登录时恢复一次；每 5 分钟低侵入检查一次"
  Say "  主动停止的隧道不会被周期任务重新连接"
  Say "  备份目录: $BACKUP_ROOT\<时间戳>"
  Say "  APPLY 后会在备份完成后停止并重新启动 Karing UI，网络可能短暂切换。"
}

function Cmd-Plan {
  param([string[]]$Arguments)
  Assert-Windows
  Resolve-KtPaths
  Parse-Options $Arguments
  if (-not $script:TAILNET_DOMAIN) { $script:TAILNET_DOMAIN = Detect-TailnetDomain }
  Show-Plan (Get-RequiredRoutes)
}

function Cmd-Backup {
  Assert-Windows
  Resolve-KtPaths
  $null = Resolve-KaringSettings $script:KARING_SETTINGS
  $path = New-Backup "manual"
  Pass "备份已创建: $path"
}

function Cmd-Backups {
  Assert-Windows
  if (-not (Test-Path -LiteralPath $BACKUP_ROOT)) { Say "还没有备份。"; return }
  Get-ChildItem -LiteralPath $BACKUP_ROOT -Directory | Sort-Object Name -Descending | ForEach-Object { $_.FullName }
}

function Cmd-Restore {
  param([string[]]$Arguments)
  Assert-Windows
  if ($Arguments.Count -lt 1) { Die "restore 需要备份目录" }
  $target = $Arguments[0]
  $unknown = @($Arguments | Select-Object -Skip 1 | Where-Object { $_ -ne "--yes" })
  if ($unknown.Count -gt 0) { Die "restore 不认识参数: $($unknown -join ', ')" }
  if ($Arguments -notcontains "--yes") {
    Say "将恢复: $target"
    $reply = Read-Host "输入 RESTORE 继续"
    if ($reply -ne "RESTORE") { Die "已取消" }
  }
  if (-not (Test-IsAdministrator)) { Die "restore 需要在同一账户的管理员 PowerShell 中运行，以恢复计划任务" }
  Resolve-KtPaths
  $null = Resolve-KaringSettings
  $rescue = New-Backup "pre-restore"
  Info "回退前保护快照: $rescue"
  try {
    Restore-BackupInternal (Resolve-Path -LiteralPath $target).Path
    Start-Sleep -Seconds 12
    if (-not (Test-HttpsReachable "https://www.apple.com" @(200, 204, 301, 302))) { throw "恢复后公网 HTTPS 不可达" }
    Pass "备份恢复完成；当前公网可达"
  } catch {
    Warn "恢复失败，正在恢复回退前保护快照: $($_.Exception.Message)"
    Restore-BackupInternal $rescue
    Die "目标备份未能安全恢复，已回到操作前状态"
  }
}

function Cmd-Configure {
  param([string[]]$Arguments)
  Assert-Windows
  Resolve-KtPaths
  Parse-Options $Arguments
  $override = $script:KARING_SETTINGS
  $null = Resolve-KaringSettings $override
  if (-not $script:KARING_PATH) { Die "找不到 Karing.exe；请先安装或设置 KTNET_KARING_APP" }
  if (-not $script:KARING_SETTINGS) { Die "找不到 karing_setting.json；请先启动 Karing，或使用 --karing-settings" }
  if (-not $script:TSPATH) { Die "找不到官方 Tailscale CLI" }
  try { Assert-TailscaleSetCapabilities } catch { Die $_.Exception.Message }
  $status = Get-TailscaleStatus
  if (-not $status -or $status.BackendState -ne "Running" -or $status.Self.Online -ne $true) { Die "请先登录并连接官方 Tailscale" }
  if (-not $script:TAILNET_DOMAIN) { $script:TAILNET_DOMAIN = Detect-TailnetDomain }
  $routes = Get-RequiredRoutes
  $config = Get-KaringConfig
  $candidate = Set-KaringDesiredFields $config $routes
  $tempCandidate = Join-Path ([IO.Path]::GetTempPath()) ("ktnet-karing-" + [Guid]::NewGuid().ToString("N") + ".json")
  Write-JsonFile $candidate $tempCandidate
  $null = Read-JsonFile $tempCandidate
  Show-Plan $routes

  if ($script:DRY_RUN) {
    Remove-Item -LiteralPath $tempCandidate -Force
    Pass "dry-run 通过：候选 JSON 可解析，没有修改系统"
    return
  }
  if (-not $script:AUTO_YES) {
    $reply = Read-Host "输入 APPLY 执行（备份后会停止并重新打开 Karing UI）"
    if ($reply -ne "APPLY") { Remove-Item -LiteralPath $tempCandidate -Force; Die "已取消" }
  }
  if (-not (Test-IsAdministrator)) {
    Remove-Item -LiteralPath $tempCandidate -Force
    Die "configure 需要在同一账户的管理员 PowerShell 中运行，以创建持久计划任务"
  }

  $backup = New-Backup "pre-configure"
  Info "备份已创建: $backup"
  try {
    $null = Stop-KaringForTransaction
    Write-KaringConfigAtomic (Read-JsonFile $tempCandidate) $script:KARING_SETTINGS
    Set-TailscaleDesired $script:ACCEPT_ROUTES
    $desired = [ordered]@{
      desiredVersion = 1
      configuredAt = (Get-Date).ToString("o")
      karingAppPath = $script:KARING_PATH
      karingSettingsPath = $script:KARING_SETTINGS
      tailnetDomain = $script:TAILNET_DOMAIN
      requiredRoutes = @($routes)
      acceptDns = $true
      acceptRoutes = $script:ACCEPT_ROUTES
      exitNode = ""
    }
    Write-JsonFile $desired $DESIRED_PATH
    Install-PersistenceTasks
    Start-Karing $script:KARING_PATH
    Remove-Item -LiteralPath $tempCandidate -Force -ErrorAction SilentlyContinue
    Info "等待隧道恢复连接"
    Start-Sleep -Seconds 15
    if (-not (Test-DesiredState)) { throw "即时端到端验证未通过" }
    Pass "Windows 持久配置已应用，并通过即时验证"
    Say "建议继续运行: ktnet verify --wait 60"
  } catch {
    Remove-Item -LiteralPath $tempCandidate -Force -ErrorAction SilentlyContinue
    Warn "配置失败，正在自动回滚: $($_.Exception.Message)"
    try {
      Restore-BackupInternal $backup
      Start-Sleep -Seconds 8
    } catch { Die "自动回滚也失败，请保留备份并人工恢复: $($_.Exception.Message)" }
    Die "配置未生效，已恢复到修改前状态"
  }
}

function Cmd-Doctor {
  Assert-Windows
  Resolve-KtPaths
  if ($CLI_ARGS.Count -gt 0) { Parse-Options $CLI_ARGS }
  $null = Resolve-KaringSettings $script:KARING_SETTINGS
  $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
  Pass "Windows: $os / $env:PROCESSOR_ARCHITECTURE"
  if ($script:KARING_PATH) { Pass "找到 Karing" } else { Fail "未找到 Karing.exe" }
  if ($script:KARING_SETTINGS) { Pass "找到 Karing 设置文件" } else { Fail "未找到 karing_setting.json" }
  if ($script:TSPATH) { Pass "找到 Tailscale CLI" } else { Fail "未找到 Tailscale CLI"; return }
  $status = Get-TailscaleStatus
  if ($status -and $status.BackendState -eq "Running" -and $status.Self.Online -eq $true) { Pass "Tailscale Running / Online" }
  else { Fail "Tailscale 未正常连接" }
  $prefs = Get-TailscalePrefs
  if ($prefs) {
    if (-not $prefs.ExitNodeID -and -not $prefs.ExitNodeIP) { Pass "未使用 Tailscale Exit Node" } else { Fail "检测到 Tailscale Exit Node" }
    Say "  accept-dns=$([bool]$prefs.CorpDNS)  accept-routes=$([bool]$prefs.RouteAll)  want-running=$([bool]$prefs.WantRunning)"
  }
  if (Test-Path -LiteralPath $DESIRED_PATH) {
    $desired = Read-JsonFile $DESIRED_PATH
    Pass "已安装 ktnet 期望状态"
    foreach ($taskName in @($STARTUP_TASK, $GUARD_TASK)) {
      if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Pass "计划任务存在: $taskName" }
      else { Fail "缺少计划任务: $taskName" }
    }
    if ($script:KARING_SETTINGS) {
      $config = Get-KaringConfig
      if (Test-KaringDesiredFields $config @($desired.requiredRoutes)) { Pass "Karing 持久字段正确" }
      else { Fail "Karing 持久字段发生漂移" }
    }
  } else { Warn "尚未执行 Windows 持久 configure" }
  if (Get-NetTCPConnection -LocalPort 1055 -State Listen -ErrorAction SilentlyContinue) { Warn "1055 端口已被占用；本方案不使用 SOCKS5" }
  else { Pass "未启用 1055 SOCKS5 备用方案" }
  if (Test-HttpsReachable "https://www.apple.com" @(200, 204, 301, 302)) { Pass "公网 HTTPS 正常" }
  else { Fail "公网 HTTPS 不可达" }
}

function Cmd-Verify {
  param([string[]]$Arguments)
  Assert-Windows
  Parse-Options $Arguments
  $rounds = if ($script:WAIT_SECONDS -gt 0) { 2 } else { 1 }
  $allOk = $true
  for ($round = 1; $round -le $rounds; $round++) {
    Info "第 $round 次验证: $(Get-Date)"
    if (-not (Test-DesiredState)) { $allOk = $false }
    if ($round -lt $rounds) { Info "等待 $script:WAIT_SECONDS 秒"; Start-Sleep -Seconds $script:WAIT_SECONDS }
  }
  if (-not $allOk) { exit 1 }
}

function Show-Usage {
  @"
ktnet - Karing + Tailscale Windows 共存工具

用法:
  ktnet doctor
  ktnet plan [配置选项]
  ktnet configure [配置选项] [--yes] [--dry-run]
  ktnet verify [--wait 秒]
  ktnet backup
  ktnet backups
  ktnet restore <备份目录> [--yes]
  ktnet open-downloads
  ktnet version

配置选项:
  --tailnet-domain 域名    通常自动识别，仅用于记录与检查
  --extra-route CIDR       Karing 额外绕过网段，可重复
  --accept-routes          接受 Tailnet 子网路由，并自动加入识别到的绕过段
  --karing-settings 路径   自动发现失败时指定 karing_setting.json
  --yes                    跳过 APPLY 文字确认
  --dry-run                只构造和验证候选配置

configure/restore 需在同一 Windows 账户的管理员 PowerShell 中运行。
guard 是计划任务内部命令，不会强制重连被主动停止的隧道。
"@
}

function Cmd-OpenDownloads {
  Info "打开官方安装页面"
  Start-Process "https://tailscale.com/download/windows"
  Start-Process "https://github.com/KaringX/karing/releases/latest"
}

switch ($Command.ToLowerInvariant()) {
  "help" { Show-Usage }
  "-h" { Show-Usage }
  "--help" { Show-Usage }
  "version" { Say "ktnet $VERSION (windows)" }
  "doctor" { Cmd-Doctor }
  "plan" { Cmd-Plan $CLI_ARGS }
  "configure" { Cmd-Configure $CLI_ARGS }
  "verify" { Cmd-Verify $CLI_ARGS }
  "backup" { if ($CLI_ARGS.Count -gt 0) { Die "backup 不接受参数" }; Cmd-Backup }
  "backups" { if ($CLI_ARGS.Count -gt 0) { Die "backups 不接受参数" }; Cmd-Backups }
  "restore" { Cmd-Restore $CLI_ARGS }
  "guard" { Cmd-Guard $CLI_ARGS }
  "open-downloads" { Cmd-OpenDownloads }
  default { Show-Usage; Die "未知命令: $Command" }
}
