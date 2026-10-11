# ASCII only. Fetches the proxy run's log, verifies the tunnel is alive,
# and writes the node link to a local file WITHOUT printing it to stdout.
param([Parameter(Mandatory = $true)][string]$RunId)

$ErrorActionPreference = 'Stop'
$repo = 'rikka661/gha-rdp'
$out = 'D:\github actions 代理\local\本地节点-勿提交.txt'
$job = (gh api "repos/$repo/actions/runs/$RunId/jobs" --jq '.jobs[0].id')
$jobId = ($job | Out-String).Trim()
Write-Output "job id = $jobId"

$log = gh api "repos/$repo/actions/jobs/$jobId/logs" 2>$null
$logText = ($log | Out-String)

$linkMatch = [regex]::Matches($logText, 'vless://[^\s"]+')
if ($linkMatch.Count -eq 0) {
    Write-Output 'FAIL: 日志里没找到 vless:// 链接'
    Write-Output ('日志末尾片段: ' + (($logText -split "`n" | Select-Object -Last 12) -join ' / ') -replace 'vless://\S+','<已隐藏>')
    exit 1
}
$link = $linkMatch[$linkMatch.Count - 1].Value
$hostMatch = [regex]::Match($link, '@([^:]+):')
$hostName = $hostMatch.Groups[1].Value
$uuidMatch = [regex]::Match($link, 'vless://([^@]+)@')
$uuid = $uuidMatch.Groups[1].Value

Write-Output ('OK: 隧道主机 = ' + $hostName)
Write-Output ('    UUID 前 6 位 = ' + $uuid.Substring(0,6) + '...（完整值只写进本地文件）')

# 探一下隧道本身活不活：直连 xray 的 ws 入口，正常应回 400（缺 Upgrade 头）
try {
    $resp = Invoke-WebRequest -Uri ('https://' + $hostName + '/') -Method Get -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop
    Write-Output ('    HTTPS 根路径返回 HTTP ' + [int]$resp.StatusCode)
} catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -gt 0) {
        Write-Output ('    HTTPS 根路径返回 HTTP ' + $code + '  -> 隧道通，xray 在应答（400 是正常，说明缺 websocket 升级头）')
    } else {
        Write-Output ('    连不上隧道：' + $_.Exception.Message)
    }
}

[System.IO.File]::WriteAllText($out, ($link + "`r`n"), [Text.Encoding]::UTF8)
Write-Output ('已写入本地文件（勿提交到 GitHub）: ' + $out)
