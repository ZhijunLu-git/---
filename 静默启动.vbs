' Silent launcher for keeper.ps1 - prevents the brief console-window flash
' that Task Scheduler causes when it runs powershell.exe in the user session.
'
' wscript.exe has no console of its own; it launches powershell HIDDEN (style 0)
' and WAITS for it, so the scheduled-task instance lives exactly as long as the
' powershell process. That keeps MultipleInstances=IgnoreNew and the 5-minute
' self-heal trigger working correctly (the task is "Running" while keeper runs).
'
' Usage:  wscript launcher.vbs            -> resident main process
'         wscript launcher.vbs watchdog   -> watchdog one-shot (adds -Watchdog)
Option Explicit
Dim sh, fso, scriptDir, keeper, extra, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
keeper = scriptDir & "\keeper.ps1"
extra = ""
If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "watchdog" Then extra = " -Watchdog"
End If
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & keeper & """" & extra
sh.Run cmd, 0, True
