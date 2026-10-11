# 只回答「这个 Secret 有没有设」，一个字都不打印它的值。
# 公开仓的 Actions 日志是全世界都能看的，这里泄一次就等于永久泄。

$fails = @()

if (-not $env:RDP_PASSWORD) {
  $fails += "RDP_PASSWORD 没设。去仓库 Settings → Secrets and variables → Actions → New repository secret，名字填 RDP_PASSWORD，值填你自己想的口令（至少 8 位，含大小写字母和数字）。"
}
if (-not $env:TS_AUTHKEY) {
  $fails += "TS_AUTHKEY 没设。去 tailscale.com 登录 → Keys 页面生成一个 auth key，名字填 TS_AUTHKEY。"
}

# 用户名只准字母数字下划线连字符，防止后面拼命令时出事。
if ($env:RDP_USER -notmatch '^[A-Za-z0-9_-]{3,20}$') {
  $fails += "RDP 用户名不合法（当前：'$env:RDP_USER'）。只能 3~20 位，字母/数字/下划线/连字符。"
}
if ($env:TS_HOSTNAME -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') {
  $fails += "Tailscale 设备名不合法（当前：'$env:TS_HOSTNAME'）。只能小写字母、数字、连字符，开头不能是连字符。"
}
if ($env:TS_AUTHKEY -and $env:TS_AUTHKEY -notmatch '^tskey-') {
  $fails += "TS_AUTHKEY 看着不像 Tailscale 的 key（正常应该以 tskey- 开头）。"
}

if ($fails.Count -gt 0) {
  Write-Host "::error::环境检查没过，共 $($fails.Count) 项："
  foreach ($f in $fails) { Write-Host "  - $f" }
  exit 1
}

Write-Host "检查通过：口令和 Tailscale key 都在位（值不打印）。"
Write-Host "用户名 = $env:RDP_USER ，设备名 = $env:TS_HOSTNAME ，本次会话 $env:SESSION_MINUTES 分钟。"
