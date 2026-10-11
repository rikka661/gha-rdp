# 本机安装 Tailscale 客户端。会弹 UAC 授权窗，点「是」。
# 单独放一个文件而不是拼一行命令，是因为 PowerShell 的嵌套引号在 bash 里转义太容易翻车。

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

Write-Output '=== 1. 确认 winget 里有这个包 ==='
winget search --id Tailscale.Tailscale --accept-source-agreements 2>&1 |
  Select-Object -First 6 | ForEach-Object { Write-Output "  $_" }

Write-Output ''
Write-Output '=== 2. 安装（注意屏幕上的 UAC 弹窗，点「是」）==='
$r = winget install --id Tailscale.Tailscale --exact --silent `
      --accept-package-agreements --accept-source-agreements 2>&1
$r | Select-Object -Last 10 | ForEach-Object { Write-Output "  $_" }
Write-Output "  winget 退出码: $LASTEXITCODE"

Write-Output ''
Write-Output '=== 3. 验证装上了没有 ==='
$cands = @(
  "$env:ProgramFiles\Tailscale\tailscale.exe",
  "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe",
  "$env:LOCALAPPDATA\Programs\Tailscale\tailscale.exe"
)
$hit = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($hit) {
  Write-Output "  找到: $hit"
  $v = & $hit version 2>&1
  Write-Output "  版本: $($v -join ' / ')"
} else {
  Write-Output '  FAIL: 找不到 tailscale.exe，安装没成功'
}

Write-Output ''
Write-Output '=== 4. 服务和进程状态 ==='
$svc = Get-Service -Name 'Tailscale*' -ErrorAction SilentlyContinue
if ($svc) {
  foreach ($s in $svc) { Write-Output "  服务 $($s.Name) = $($s.Status) / 启动类型 $($s.StartType)" }
} else {
  Write-Output '  还没有 Tailscale 服务（可能要点「登录」才会拉起，正常）'
}
$proc = Get-Process -Name 'Tailscale*' -ErrorAction SilentlyContinue
if ($proc) {
  foreach ($p in $proc) { Write-Output "  进程 $($p.ProcessName) pid=$($p.Id)" }
} else {
  Write-Output '  没有 Tailscale 进程在跑'
}

Write-Output ''
Write-Output '=== 5. 顺带看一眼 Clash Verge 还在不在跑（装完要处理它的 TUN 冲突）==='
$cv = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'clash|verge|mihomo' }
foreach ($p in $cv) { Write-Output "  $($p.ProcessName) pid=$($p.Id)" }
