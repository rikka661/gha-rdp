# ASCII ONLY. PowerShell 5.1 reads BOM-less UTF-8 as GBK and mangles CJK strings,
# which swallows quotes and breaks parsing. Keep this file pure ASCII.

$ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) { Write-Output 'NO tailscale.exe'; exit 1 }

Write-Output '===== 1. login and backend state ====='
$j = & $ts status --json 2>$null | ConvertFrom-Json
Write-Output ('  BackendState : ' + $j.BackendState)
Write-Output ('  self         : ' + $j.Self.Hostname + '  ' + $j.Self.Addresses[0])
Write-Output ('  tailnet user : ' + $j.UserLoginName)
Write-Output ('  peers        : ' + (@($j.Peer).Count) + '   (2 once the Actions runner joins)')
Write-Output ('  MagicDNS     : ' + $j.MagicDNSEnabled + '   (we skipped their DNS on purpose; use raw IPs)')

Write-Output '===== 2. tailscale interface IP ====='
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -like '100.*' } |
  ForEach-Object { Write-Output ('  ' + $_.IPAddress + '  if=' + $_.InterfaceAlias + '  origin=' + $_.PrefixOrigin) }

Write-Output '===== 3. routing ownership (coexistence with Mihomo TUN) ====='
Write-Output '  -- aggregate 100.64.0.0/10 route? --'
$r = Get-NetRoute -DestinationPrefix '100.64.0.0/10' -ErrorAction SilentlyContinue
if ($r) {
    foreach ($x in $r) { Write-Output ('    if=' + $x.InterfaceAlias + ' next=' + $x.NextHop + ' metric=' + $x.RouteMetric) }
} else {
    Write-Output '    none (normal: Tailscale adds a /32 host route per peer; no peers yet)'
}

Write-Output '  -- any /32 routes into 100.x --'
$r32 = Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -like '100.*' }
if ($r32) { foreach ($x in $r32) { Write-Output ('    ' + $x.DestinationPrefix + ' if=' + $x.InterfaceAlias) } }
else { Write-Output '    none yet (should appear for the runner once it joins, owned by Tailscale)' }

Write-Output '  -- default routes --'
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output ('    if=' + $_.InterfaceAlias + ' next=' + $_.NextHop + ' metric=' + $_.RouteMetric)
}

Write-Output '===== 4. control plane reachable through current link ====='
foreach ($u in @('https://login.tailscale.com', 'https://controlplane.tailscale.com')) {
    try {
        $resp = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 15 -UseBasicParsing
        Write-Output ('  ' + $u + ' -> HTTP ' + $resp.StatusCode)
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -gt 0) { Write-Output ('  ' + $u + ' -> HTTP ' + $code + ' (reachable, HEAD refused)') }
        else { Write-Output ('  ' + $u + ' -> UNREACHABLE: ' + $_.Exception.Message) }
    }
}

Write-Output '===== 5. is this PC itself open to inbound RDP? ====='
$deny = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
if ($deny -eq 1) { Write-Output '  fDenyTSConnections=1  -> inbound RDP to this PC is OFF (good)' }
elseif ($deny -eq 0) { Write-Output '  fDenyTSConnections=0  -> WARNING: this PC accepts inbound RDP' }
else { Write-Output ('  fDenyTSConnections=' + $deny + '  (unknown value)') }
