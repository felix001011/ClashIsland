' Disable auto-start at login: removes the Startup folder shortcut
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
startup = sh.SpecialFolders("Startup")
lnkPath = startup & "\ClashIsland.lnk"
If fso.FileExists(lnkPath) Then
    fso.DeleteFile lnkPath
    MsgBox "Auto-start disabled.", 64, "ClashIsland"
Else
    MsgBox "Auto-start was not enabled.", 64, "ClashIsland"
End If
