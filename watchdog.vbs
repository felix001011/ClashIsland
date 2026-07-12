' ClashIsland watchdog - runs every minute via Task Scheduler.
' Starts the island when Clash Verge is running but the island is not.
' A ".manual-exit" marker (created when the user quits via the context menu)
' suppresses the restart until Clash itself is closed once.
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
marker = dir & "\.manual-exit"
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set clash = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='clash-verge.exe'")
If clash.Count = 0 Then
    ' Clash is closed: clear the manual-exit marker so the island returns on next launch
    If fso.FileExists(marker) Then fso.DeleteFile marker
    WScript.Quit
End If
If fso.FileExists(marker) Then WScript.Quit
Set isl = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='powershell.exe' AND CommandLine LIKE '%ClashIsland.ps1%'")
If isl.Count = 0 Then
    Set sh = CreateObject("WScript.Shell")
    sh.Run "wscript.exe """ & dir & "\start.vbs""", 0, False
End If
