# uninstall.ps1 — 停止并删除两个计划任务（常驻主进程 + 看门狗）
#
# 这两个任务以 SYSTEM 身份注册，删除同样需要管理员权限；若未提权则自动以管理员身份重启（弹一次 UAC）。

$wi = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($wi)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath)
    )
    exit
}

foreach ($taskName in @('断网自动重连', '断网自动重连-看门狗')) {
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host ("已删除任务 [{0}]。" -f $taskName)
    } catch {
        Write-Host ("没有找到任务 [{0}]，可能尚未安装过。" -f $taskName)
    }
}
