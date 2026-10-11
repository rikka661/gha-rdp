# 让这台 runner 主动加入你的 Tailscale 私有网。
# 走的是「runner 往外连」，不是「你往里连」——这正好绕开 Actions 没有公网 IP、
# 外部连不进去那道硬墙，而且不需要任何第三方中继，地址和口令都不用出现在日志里。

$ErrorActionPreference = 'Continue'

function Get-TsExe {
  foreach ($p in @(
      "$env:ProgramFiles\Tailscale\tailscale.exe",
      "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

# key 有可能被 tailscale 自己回显到输出里，凡是往控制台打印的地方都先过一遍这个。
function Protect($text) {
  if (-not $text) { return '' }
  $s = $text -join "`n"
  if ($env:TS_AUTHKEY -and $s -match [regex]::Escape($env:TS_AUTHKEY)) {
    $s = $s -replace [regex]::Escape($env:TS_AUTHKEY), '***'
  }
  return $s
}

Write-Host "== 1. 装 Tailscale =="
$ts = Get-TsExe
if (-not $ts) {
  $work = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  $msi = Join-Path $work 'tailscale-setup.msi'
  $url = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 180
    Write-Host "  下载完成：$((Get-Item $msi).Length) 字节"
  } catch {
    Write-Host "::error::Tailscale 安装包下载失败：$($_.Exception.Message)"
    exit 1
  }
  $r = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
  Write-Host "  msiexec 退出码 $($r.ExitCode)"
  $ts = Get-TsExe
  if (-not $ts) { Write-Host "::error::装完还是找不到 tailscale.exe"; exit 1 }
}
Write-Host "  用的可执行文件：$ts"
Write-Host "  版本：$(Protect (& $ts version 2>&1))"

Write-Host "== 2. 确保后台服务在跑 =="
foreach ($svc in @('Tailscale', 'TailscaleUpLauncher')) {
  $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
  if ($s) {
    if ($s.Status -ne 'Running') {
      try { Start-Service $svc -ErrorAction Stop; Write-Host "  $svc 已启动" }
      catch { Write-Host "  $svc 启动失败：$($_.Exception.Message)" }
    } else { Write-Host "  $svc 本来就在跑" }
  }
}

Write-Host "== 3. 登录进你的私有网 =="
# 下面这些参数全部对着 `tailscale up --help` 原文核过（1.104.1 实测）：
#   --auth-key     存在（--authkey 不存在，别写错）
#   --hostname     存在
#   --unattended   存在，Windows-only：GUI 用户注销后连接仍保持
#   --timeout      存在；不写的话默认 0s = 永远阻塞，那就只能靠外面手动掐
#   --accept-dns   我们显式关掉：runner 上不需要 MagicDNS，本地用裸 100.x IP 连
#   不用 --shields-up：那个会拒绝所有入站连接，而我们要的就是让他的电脑连进来 3389
#
# 因为有原生 --timeout，这里不再用 Start-Job 手动掐超时。
$upOk = $false
foreach ($extra in @('--unattended', $null)) {
  $argv = @('up', "--auth-key=$env:TS_AUTHKEY", "--hostname=$env:TS_HOSTNAME",
            '--accept-dns=false', '--timeout=2m')
  if ($extra) { $argv += $extra }
  $label = if ($extra) { "up（带 $extra）" } else { 'up（不带 unattended）' }
  Write-Host "  尝试 $label"

  $out = Protect (& $ts @argv 2>&1)
  if ($out.Trim()) { Write-Host "  输出：$($out.Trim())" }
  if ($out -match '(?i)\berror\b|invalid|unknown flag|not recognized') {
    Write-Host "  这次没成，换下一种"
    continue
  }
  $upOk = $true
  break
}

Write-Host "== 4. 查它在私有网里的地址 =="
Start-Sleep -Seconds 6
$status = Protect (& $ts status --json 2>&1)

$ip = $null; $dns = $null
try {
  $j = $status | ConvertFrom-Json
  $ip = ($j.Self.Addresses | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
  $dns = $j.Self.DNSName
} catch { Write-Host "  状态解析失败（不影响，看下面原始输出）" }

if (-not $ip) {
  $lines = Protect (& $ts ips 2>&1)
  if ($lines -match '(100\.\d+\.\d+\.\d+)') { $ip = $Matches[1] }
}

Write-Host ""
Write-Host "=================== 本机接入结果 ==================="
Write-Host "  up 命令是否成功 : $upOk"
Write-Host "  设备名          : $env:TS_HOSTNAME"
Write-Host "  私有网 IP       : $(if ($ip) { $ip } else { '没拿到，见下方原始状态' })"
Write-Host "  MagicDNS 域名   : $(if ($dns) { $dns } else { '没开 MagicDNS，直接用上面那个 100.x IP' })"
Write-Host "  用户名          : $env:RDP_USER"
Write-Host "  （口令就是你在 Secrets 里设的那串，这里不显示、不进日志）"
Write-Host ""
if ($ip) {
  Write-Host "  本地怎么连：开始菜单搜 mstsc → 计算机填 $ip → 用户名 $env:RDP_USER"
  Write-Host "  手机同理：装 Tailscale App 登同一个账号，再用 Remote Desktop 类 App 连同一个地址"
} else {
  Write-Host "::warning::没拿到 100.x 地址。多半是 key 不对、key 是一次性的且已用掉、或者 ACL 拦了。原始状态："
  Write-Host $status
}
Write-Host "===================================================="
