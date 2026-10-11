# 在这台一次性的 Windows runner 上开远程桌面：建个本地账号 + 放行 3389。
# 全是 try/catch 兜住：任何一步失败只记一笔，不中断整个会话。
# 最后打印的是「能不能连」的体检结果，绝不打印口令。

$ErrorActionPreference = 'Continue'
$u = $env:RDP_USER
$log = @()

function Note($k, $v) {
  $script:log += ("  {0,-26} {1}" -f $k, $v)
}

Write-Host "== 1. 建本地账号 =="
$sp = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force
try {
  # 已存在就只改口令（正常不会存在，这是防重复触发的保险）
  if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $u -Password $sp -PasswordNeverExpires $true -AccountNeverExpires
    Note "账号 $u" "已存在，口令已刷新"
  } else {
    # 参数一批喂过去；万一这个镜像的 cmdlet 版本不认 -AccountNeverExpires，
    # 退到最少的参数再来一次，别让一个可选参数把整个会话带走。
    try {
      New-LocalUser -Name $u -Password $sp -FullName 'AI Deck' -PasswordNeverExpires -AccountNeverExpires | Out-Null
      Note "账号 $u" "已创建"
    } catch {
      New-LocalUser -Name $u -Password $sp -PasswordNeverExpires | Out-Null
      Note "账号 $u" "已创建（退到精简参数：$($_.Exception.Message)）"
    }
  }
} catch {
  Write-Host "::error::建账号失败：$($_.Exception.Message)"
  exit 1
}

Write-Host "== 2. 放进两个组 =="
foreach ($g in @('Administrators', 'Remote Desktop Users')) {
  try {
    Add-LocalGroupMember -Group $g -Member $u -ErrorAction Stop
    Note "组成员 $g" "已加入"
  } catch {
    Note "组成员 $g" "没加进去：$($_.Exception.Message)"
  }
}

# 管理员账号走远程桌面默认拿到的是受限令牌，这一下让它带上完整权限，
# 不然进去后会发现很多设置改不了、盘也打不开。
try {
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy' -Type DWord -Value 1 -Force
  Note "LocalAccountTokenFilterPolicy" "已设为 1"
} catch { Note "LocalAccountTokenFilterPolicy" "设失败：$($_.Exception.Message)" }

Write-Host "== 3. 打开远程桌面开关 =="
$tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
try {
  Set-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -Type DWord -Value 0 -Force
  Note "fDenyTSConnections" "0（允许连接）"
} catch {
  # 属性可能不存在，用新建的方式再来一次
  try {
    New-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -PropertyType DWord -Value 0 -Force | Out-Null
    Note "fDenyTSConnections" "0（新建属性成功）"
  } catch { Write-Host "::error::开远程桌面失败：$($_.Exception.Message)"; exit 1 }
}

Write-Host "== 4. 起 TermService 服务 =="
try {
  Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
  if ((Get-Service TermService).Status -ne 'Running') { Start-Service TermService -ErrorAction Stop }
  Note "TermService" (Get-Service TermService).Status
} catch { Note "TermService" "起服务失败：$($_.Exception.Message)" }

Write-Host "== 5. 防火墙放行 3389 =="
# 直接按端口加规则，不碰「远程桌面」这个规则组名 —— 规则组名跟着系统界面语言走，
# 镜像语言一换就找不到，按端口加是最稳的写法。
try {
  Remove-NetFirewallRule -DisplayName 'AI-RDP-3389' -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName 'AI-RDP-3389' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 3389 -Profile Any -Enable True | Out-Null
  Note "防火墙规则 AI-RDP-3389" "已放行"
} catch { Note "防火墙规则 AI-RDP-3389" "加失败：$($_.Exception.Message)" }

Write-Host "== 6. 保留 NLA（网络级身份验证）=="
# 故意不关。关掉虽然连得上更多老客户端，但等于把口令验证挪到桌面之后，
# 这台机器对整个互联网（经 Tailscale）开放，NLA 必须先挡住爆破。
try {
  Set-ItemProperty -Path "$tsKey\WinStations\RDP-Tcp" -Name 'UserAuthentication' -Type DWord -Value 1 -Force
  Note "UserAuthentication" "1（要求 NLA）"
} catch { Note "UserAuthentication" "设失败：$($_.Exception.Message)" }

Write-Host "== 7. 体检：3389 到底在听没有 =="
$listen = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
if ($listen) {
  Note "TCP 3389 监听" "有，进程 $($listen[0].OwningProcess)"
} else {
  Write-Host "::warning::3389 没在监听，可能连不上。等 5 秒再查一次。"
  Start-Sleep -Seconds 5
  $listen2 = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
  if ($listen2) { Note "TCP 3389 监听" "延迟后有了" } else { Write-Host "::error::3389 仍然没监听" }
}

Write-Host ""
Write-Host "远程桌面准备情况："
$log | ForEach-Object { Write-Host $_ }
