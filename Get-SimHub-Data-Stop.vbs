Set objShell = CreateObject("Wscript.shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

shellMacrosDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
simHubDir = objFSO.GetParentFolderName(shellMacrosDir)
webhooksDir = objFSO.BuildPath(simHubDir, "Webhooks")
dataDir = objFSO.BuildPath(webhooksDir, "data")
scriptPath = objFSO.BuildPath(webhooksDir, "Get-SimHub-Data.ps1")

stopCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoLogo -NonInteractive -File " & Chr(34) & scriptPath & Chr(34) & " -Stop -DataDir " & Chr(34) & dataDir & Chr(34)

objShell.Run stopCommand, 0, True

Set objShell = Nothing
Set objFSO = Nothing
