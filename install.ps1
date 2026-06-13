# install.ps1 — 注册两个计划任务：
#   1) 常驻主进程：开机自启，每 30 秒检测一次，断网立即重连
#   2) 看门狗：每 3 分钟独立跑一次，万一主进程卡死/退出仍能把网络救回来（远程机器的保险）
#
# 触发器经过加固，能扛住「系统睡眠/休眠唤醒」和「进程被意外掐断」：
#   - 主进程：除了登录时启动，额外挂一个「每 5 分钟」的时间型自愈触发器，
#     配合 MultipleInstances=IgnoreNew —— 进程还活着就忽略，死了就在 5 分钟内自动拉起。
#   - 看门狗：改用「时间型 + 每 3 分钟重复 + StartWhenAvailable」，
#     不再依赖 AtLogOn（AtLogOn 的重复计划在睡眠唤醒后会失效，这正是之前看门狗停摆的原因）。

$ErrorActionPreference = 'Stop'
$mainTask  = '断网自动重连'
$dogTask   = '断网自动重连-看门狗'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$keeper    = Join-Path $scriptDir 'keeper.ps1'
$me        = "$env:USERDOMAIN\$env:USERNAME"

function New-HiddenAction {
    param([string]$ExtraArg)
    return (New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"{1}' -f $keeper, $ExtraArg))
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
    $mainAction   = New-HiddenAction -ExtraArg ''
    # 触发器：开机/登录时启动 + 每 5 分钟自愈一次（死了就重新拉起，没死就被 IgnoreNew 忽略）
    $mainTriggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $me),
        (New-RepeatingTrigger -IntervalMinutes 5)
    )
    $mainSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $mainTask -Action $mainAction -Trigger $mainTriggers -Settings $mainSettings `
        -Description "检测断网并自动登录上网认证（脚本目录: $scriptDir）" -Force | Out-Null
    Start-ScheduledTask -TaskName $mainTask

    # ---- 2) 看门狗：每 3 分钟跑一次 keeper.ps1 -Watchdog ----
    $dogAction   = New-HiddenAction -ExtraArg ' -Watchdog'
    $dogTrigger  = New-RepeatingTrigger -IntervalMinutes 3
    $dogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $dogTask -Action $dogAction -Trigger $dogTrigger -Settings $dogSettings `
        -Description "看门狗：每 3 分钟独立检测一次，主进程失效时兜底重连（脚本目录: $scriptDir）" -Force | Out-Null
    Start-ScheduledTask -TaskName $dogTask

    Write-Host "已创建两个任务并开始运行："
    Write-Host ("  1) 常驻主进程 [{0}]：每 30 秒检测，断网立即重连（每 5 分钟自愈，进程被掐断也能自己回来）" -f $mainTask)
    Write-Host ("  2) 看门狗     [{0}]：每 3 分钟兜底，睡眠唤醒后也照常运行" -f $dogTask)
    Write-Host ""
    Write-Host ("事件日志: " + (Join-Path $scriptDir '运行日志.txt'))
    Write-Host ("存活心跳: " + (Join-Path $scriptDir '最近检测.txt') + " （随时打开看最后检测时间，确认还活着）")
} catch {
    Write-Host ("安装失败: " + $_.Exception.Message)
    exit 1
}
