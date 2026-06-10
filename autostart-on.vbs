' Enable auto-start at login: creates a shortcut in the user's Startup folder
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
startup = sh.SpecialFolders("Startup")
Set lnk = sh.CreateShortcut(startup & "\ClashIsland.lnk")
lnk.TargetPath = "C:\Windows\System32\wscript.exe"
lnk.Arguments = """" & dir & "\start.vbs"""
lnk.WorkingDirectory = dir
lnk.Description = "ClashIsland - Clash Verge floating island"
lnk.Save
MsgBox "OK! ClashIsland will start automatically at login.", 64, "ClashIsland"
