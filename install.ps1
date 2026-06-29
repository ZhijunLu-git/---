# install.ps1 — 注册两个计划任务：
#   1) 常驻主进程：开机自启，每 30 秒检测一次，断网立即重连
#   2) 看门狗：每 3 分钟独立跑一次，万一主进程卡死/退出仍能把网络救回来（远程机器的保险）
#
# 两个任务都以 SYSTEM 身份运行（LogonType=ServiceAccount，内置账户、无需任何密码），
# 且「不管用户是否登录都运行」—— 开机后 / 锁屏 / 注销 / 无人登录时掉网都能自动重连。
# 这是远程机的关键：早先用 Interactive（只在用户登录时运行），掉网时若无人登录就一直断着，
# 非得有人进桌面建立会话才会重连。注册 SYSTEM 任务需要管理员权限，本脚本会自动提权（弹一次 UAC）。
#
# 触发器经过加固，能扛住「系统睡眠/休眠唤醒」和「进程被意外掐断」：
#   - 主进程：开机启动（AtStartup）+ 额外挂一个「每 5 分钟」的时间型自愈触发器，
#     配合 MultipleInstances=IgnoreNew —— 进程还活着就忽略，死了就在 5 分钟内自动拉起。
#   - 看门狗：「时间型 + 每 3 分钟重复 + StartWhenAvailable」，
#     不依赖 AtLogOn（AtLogOn 的重复计划在睡眠唤醒后会失效，且必须用户登录才生效）。
#
# 启动方式经由 静默启动.vbs（wscript）拉起 powershell，彻底消除「每次检测一闪而过的终端窗口」：
#   直接用 powershell.exe -WindowStyle Hidden 仍会在 conhost 创建窗口的瞬间闪一下；
#   wscript 自身没有控制台，且以隐藏方式(SW_HIDE)启动 powershell，从头到尾不出现任何窗口。

$ErrorActionPreference = 'Stop'

# 注册 SYSTEM 任务需要管理员权限；若未提权，自动以管理员身份重启本脚本（会弹一次 UAC）。
$wi = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($wi)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath)
    )
    exit
}

$mainTask  = '断网自动重连'
$dogTask   = '断网自动重连-看门狗'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs       = Join-Path $scriptDir '静默启动.vbs'

# 以 SYSTEM 运行，并「不管用户是否登录都运行」。SYSTEM 是内置账户，注册时不需要任何密码。
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# 经 wscript 静默拉起 keeper.ps1。Mode='' 为常驻主进程，Mode='watchdog' 为看门狗。
function New-HiddenAction {
    param([string]$Mode)
    $arg = '"{0}"' -f $vbs
    if ($Mode -ne '') { $arg = $arg + ' ' + $Mode }
    return (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arg)
}

# 时间型重复触发器：从 1 分钟前开始，每 N 分钟重复一次（持续 10 年≈永久）。
# 时间型触发器配合 StartWhenAvailable，在睡眠/休眠唤醒后能自动补跑漏掉的那次，
# 比挂在 AtLogOn 上的重复计划健壮得多。
function New-RepeatingTrigger {
    param([int]$IntervalMinutes)
    $t = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(-1))
    $t.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    return $t
}

try {
    # ---- 1) 常驻主进程 ----
    $mainAction   = New-HiddenAction -Mode ''
    # 触发器：开机启动(AtStartup) + 每 5 分钟自愈一次（死了就重新拉起，没死就被 IgnoreNew 忽略）
    $mainTriggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-RepeatingTrigger -IntervalMinutes 5)
    )
    $mainSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $mainTask -Action $mainAction -Trigger $mainTriggers -Settings $mainSettings `
        -Principal $principal -Description "检测断网并自动登录上网认证（脚本目录: $scriptDir）" -Force | Out-Null
    Start-ScheduledTask -TaskName $mainTask

    # ---- 2) 看门狗：每 3 分钟跑一次 keeper.ps1 -Watchdog ----
    $dogAction   = New-HiddenAction -Mode 'watchdog'
    $dogTrigger  = New-RepeatingTrigger -IntervalMinutes 3
    $dogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $dogTask -Action $dogAction -Trigger $dogTrigger -Settings $dogSettings `
        -Principal $principal -Description "看门狗：每 3 分钟独立检测一次，主进程失效时兜底重连（脚本目录: $scriptDir）" -Force | Out-Null
    Start-ScheduledTask -TaskName $dogTask

    Write-Host "已创建两个任务并开始运行（经 静默启动.vbs 拉起，全程无终端窗口）："
    Write-Host ("  1) 常驻主进程 [{0}]：每 30 秒检测，断网立即重连（每 5 分钟自愈，进程被掐断也能自己回来）" -f $mainTask)
    Write-Host ("  2) 看门狗     [{0}]：每 3 分钟兜底，睡眠唤醒后也照常运行" -f $dogTask)
    Write-Host ""
    Write-Host ("事件日志: " + (Join-Path $scriptDir '运行日志.txt'))
    Write-Host ("存活心跳: " + (Join-Path $scriptDir '最近检测.txt') + " （随时打开看最后检测时间，确认还活着）")
} catch {
    Write-Host ("安装失败: " + $_.Exception.Message)
    exit 1
}
