' Disable auto-start: removes the Startup shortcut and the watchdog task
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
startup = sh.SpecialFolders("Startup")
lnkPath = startup & "\ClashIsland.lnk"
If fso.FileExists(lnkPath) Then fso.DeleteFile lnkPath
sh.Run "schtasks /Delete /F /TN ClashIslandWatchdog", 0, True
MsgBox "Auto-start and watchdog disabled.", 64, "ClashIsland"
