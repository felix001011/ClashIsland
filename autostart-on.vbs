' Enable auto-start: Startup shortcut (instant start at login)
' plus a watchdog scheduled task (restarts the island whenever
' Clash Verge is running but the island is not, checks every minute)
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")

' 1. Startup folder shortcut
startup = sh.SpecialFolders("Startup")
Set lnk = sh.CreateShortcut(startup & "\ClashIsland.lnk")
lnk.TargetPath = "C:\Windows\System32\wscript.exe"
lnk.Arguments = """" & dir & "\start.vbs"""
lnk.WorkingDirectory = dir
lnk.Description = "ClashIsland - Clash Verge floating island"
lnk.Save

' 2. Watchdog scheduled task (every minute)
q = Chr(34)
tr = q & "wscript.exe \" & q & dir & "\watchdog.vbs\" & q & q
cmd = "schtasks /Create /F /TN ClashIslandWatchdog /SC MINUTE /MO 1 /TR " & tr
rc = sh.Run(cmd, 0, True)

If rc = 0 Then
    MsgBox "OK! ClashIsland will start at login and follow Clash Verge automatically.", 64, "ClashIsland"
Else
    MsgBox "Startup shortcut created, but the watchdog task failed (code " & rc & ").", 48, "ClashIsland"
End If
