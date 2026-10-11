# ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less UTF-8 as GBK and
# mangles multi-byte chars, which can swallow quotes and break parsing.
# Keep this file pure-ASCII so it runs the same on 5.1 and 7.x.

$exe = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (-not (Test-Path $exe)) { $exe = "$env:LOCALAPPDATA\Programs\Tailscale\tailscale.exe" }

if (-not (Test-Path $exe)) {
    Write-Output 'STATE: NOT INSTALLED'
    $procs = Get-Process -Name 'Tailscale*' -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) { Write-Output ('  stray process ' + $p.ProcessName + ' pid=' + $p.Id) }
    }
    Write-Output 'WINGET LIST:'
    winget list --id Tailscale.Tailscale 2>&1 | Select-Object -First 4 | ForEach-Object { Write-Output ('  ' + $_) }
    exit 0
}

Write-Output ('STATE: INSTALLED at ' + $exe)
$ver = & $exe version 2>&1
Write-Output ('VERSION: ' + ($ver -join ' / '))

$svc = Get-Service -Name 'Tailscale*' -ErrorAction SilentlyContinue
if ($svc) {
    foreach ($s in $svc) { Write-Output ('SERVICE ' + $s.Name + ' = ' + $s.Status + ' / ' + $s.StartType) }
} else {
    Write-Output 'SERVICE: none found'
}

Write-Output 'TAILSCALE STATUS:'
& $exe status 2>&1 | Select-Object -First 8 | ForEach-Object { Write-Output ('  ' + $_) }

Write-Output 'LOCAL IP ON TAILNET:'
& $exe ip -4 2>&1 | Select-Object -First 3 | ForEach-Object { Write-Output ('  ' + $_) }

Write-Output 'ADAPTER:'
$ad = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tailscale' }
if ($ad) {
    foreach ($a in $ad) { Write-Output ('  ' + $a.Name + ' | ' + $a.Status + ' | ' + $a.InterfaceDescription) }
} else {
    Write-Output '  no Tailscale adapter yet'
}

Write-Output 'PROXY ADAPTERS PRESENT (conflict watch):'
$mx = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Mihomo|Clash|Wiresock' }
foreach ($a in $mx) { Write-Output ('  ' + $a.Name + ' | ' + $a.Status) }

Write-Output 'DEFAULT ROUTES:'
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output ('  if=' + $_.InterfaceAlias + ' next=' + $_.NextHop + ' metric=' + $_.RouteMetric)
}
