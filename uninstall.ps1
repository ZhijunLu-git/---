# uninstall.ps1 — 停止并删除两个计划任务（常驻主进程 + 看门狗）

foreach ($taskName in @('断网自动重连', '断网自动重连-看门狗')) {
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host ("已删除任务 [{0}]。" -f $taskName)
    } catch {
        Write-Host ("没有找到任务 [{0}]，可能尚未安装过。" -f $taskName)
    }
}
