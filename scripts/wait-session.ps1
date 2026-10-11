# 挂在这里等会话结束。什么都没干，就是不让 job 结束——
# job 一结束这台机器就被销毁，你的远程桌面跟着没。
#
# 想提前收工：Actions 页面右上角「Cancel workflow」点一下就行，一个按钮，
# 不用等时长跑满。收尾脚本带 if: always()，取消也会执行，不会在你的私有网里留僵尸节点。

$total = [int]$env:SESSION_MINUTES
if ($total -le 0) { $total = 25 }

$started = Get-Date
$end = $started.AddMinutes($total)
Write-Host "会话将在 $total 分钟后自动结束（约 $($end.ToString('HH:mm:ss')) UTC）。"
Write-Host "想提前收工 → Actions 页面点 Cancel workflow。"
Write-Host ""

$beat = 0
while ((Get-Date) -lt $end) {
  $left = [int]($end - (Get-Date)).TotalMinutes
  if ($left -lt 0) { $left = 0 }

  # 每 5 分钟报一次活，方便你在日志里看出这台机器还在，不是卡死
  if ($beat % 5 -eq 0) {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] 还在跑，剩余约 $left 分钟。本地用 mstsc 连私有网 IP 即可。"
  }

  $sleepTo = $end
  if ((Get-Date).AddMinutes(1) -lt $sleepTo) { $sleepTo = (Get-Date).AddMinutes(1) }
  $ms = [int]($sleepTo - (Get-Date)).TotalMilliseconds
  if ($ms -lt 1000) { $ms = 1000 }
  Start-Sleep -Milliseconds $ms
  $beat++
}

Write-Host ""
Write-Host "时长用完，准备收工。机器随后会被销毁，桌面里的东西不保留（这是设计如此，不是坏了）。"
