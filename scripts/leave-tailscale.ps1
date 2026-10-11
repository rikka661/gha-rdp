# 收尾：退出登录 + 尽量把这台设备从你的私有网里彻底删掉。
# 这一步带 if: always()，成功、失败、被取消都会跑到。
#
# 为什么要专门删：Actions 每跑一次就是一台新机器，如果只 down 不删，
# 你的 Tailscale 设备列表会越堆越多，看着乱、也容易被人认错。

function Get-TsExe {
  foreach ($p in @(
      "$env:ProgramFiles\Tailscale\tailscale.exe",
      "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Protect($text) {
  if (-not $text) { return '' }
  $s = $text -join "`n"
  foreach ($secret in @($env:TS_AUTHKEY, $env:TS_API_TOKEN)) {
    if ($secret -and $s -match [regex]::Escape($secret)) {
      $s = $s -replace [regex]::Escape($secret), '***'
    }
  }
  return $s
}

$ts = Get-TsExe
if (-not $ts) {
  Write-Host "没找到 tailscale.exe（可能压根没装上），跳过退网。"
  exit 0
}

# 设备 ID 先记下来，后面要用它调 API 删除
$deviceJson = Protect (& $ts status --json 2>&1)
$deviceID = $null
try {
  $deviceID = ($deviceJson | ConvertFrom-Json).Self.ID
} catch { Write-Host "  状态解析失败，跳过 ID 记录" }

Write-Host "== 1. 退出登录 =="
Write-Host (Protect (& $ts logout 2>&1))

Write-Host "== 2. 断开网络 =="
Write-Host (Protect (& $ts down 2>&1))

Write-Host "== 3. 从私有网里删除这台设备 =="
# 需要另设一个 TS_API_TOKEN（Tailscale 管理页 Admin → Keys → API tokens，
# 角色选 Operator 或 IT support 就够）。不设也能用，只是设备会留在列表里，
# 你去网页上手点两下 Delete 也一样。
if (-not $env:TS_API_TOKEN) {
  Write-Host "  没设 TS_API_TOKEN，跳过。设备会留在列表里，名字是 $env:TS_HOSTNAME，想要干净就去网页删一下。"
  exit 0
}
if (-not $deviceID) {
  Write-Host "  没拿到设备 ID，跳过自动删除。"
  exit 0
}

try {
  $pair = "{0}:" -f $env:TS_API_TOKEN          # Tailscale 的 API 用 basic 认证，密码留空
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
  $resp = Invoke-RestMethod -Method Delete `
    -Uri "https://api.tailscale.com/api/v2/tailnet/-/devices/$deviceID" `
    -Headers @{ Authorization = "Basic $b64" } -TimeoutSec 60
  Write-Host "  已请求删除设备 $deviceID。"
} catch {
  Write-Host "::warning::自动删除失败（不影响账号安全，只是列表里会多一条记录）：$($_.Exception.Message)"
}
