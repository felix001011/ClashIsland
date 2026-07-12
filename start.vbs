' ClashIsland launcher - starts the widget with no console window
' Works from any folder (resolves its own location)
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
' Manual start always clears the manual-exit marker
If fso.FileExists(dir & "\.manual-exit") Then fso.DeleteFile dir & "\.manual-exit"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\ClashIsland.ps1""", 0, False
