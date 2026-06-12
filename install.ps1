# install.ps1 — 注册两个计划任务：
#   1) 常驻主进程：开机自启，每 30 秒检测一次，断网立即重连
#   2) 看门狗：每 3 分钟独立跑一次，万一主进程卡死/退出仍能把网络救回来（远程机器的保险）

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

try {
    # ---- 1) 常驻主进程 ----
    $mainAction  = New-HiddenAction -ExtraArg ''
    $mainTrigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $mainSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $mainTask -Action $mainAction -Trigger $mainTrigger -Settings $mainSettings `
        -Description "检测断网并自动登录上网认证（脚本目录: $scriptDir）" -Force | Out-Null
    Start-ScheduledTask -TaskName $mainTask

    # ---- 2) 看门狗：每 3 分钟跑一次 keeper.ps1 -Watchdog ----
    $dogAction = New-HiddenAction -ExtraArg ' -Watchdog'
    # 开机后 1 分钟开始，之后每 3 分钟重复一次，持续 10 年（实际等同永久）
    $dogTrigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $dogTrigger.Delay = 'PT1M'
    $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $dogTrigger.Repetition = $rep
    $dogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $dogTask -Action $dogAction -Trigger $dogTrigger -Settings $dogSettings `
        -Description "看门狗：每 3 分钟独立检测一次，主进程失效时兜底重连（脚本目录: $scriptDir）" -Force | Out-Null
    Start-ScheduledTask -TaskName $dogTask

    Write-Host "已创建两个任务并开始运行："
    Write-Host ("  1) 常驻主进程 [{0}]：每 30 秒检测，断网立即重连" -f $mainTask)
    Write-Host ("  2) 看门狗     [{0}]：每 3 分钟兜底，主进程失效时救援" -f $dogTask)
    Write-Host ""
    Write-Host ("事件日志: " + (Join-Path $scriptDir '运行日志.txt'))
    Write-Host ("存活心跳: " + (Join-Path $scriptDir '最近检测.txt') + " （随时打开看最后检测时间，确认还活着）")
} catch {
    Write-Host ("安装失败: " + $_.Exception.Message)
    exit 1
}
