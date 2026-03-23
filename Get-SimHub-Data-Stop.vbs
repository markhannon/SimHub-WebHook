Set objShell = CreateObject("Wscript.shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

shellMacrosDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
simHubDir = objFSO.GetParentFolderName(shellMacrosDir)
webhooksDir = objFSO.BuildPath(simHubDir, "Webhooks")
dataDir = objFSO.BuildPath(webhooksDir, "data")
If Not objFSO.FolderExists(dataDir) Then
	objFSO.CreateFolder dataDir
End If
logPath = objFSO.BuildPath(dataDir, "_scripts.log")
scriptPath = objFSO.BuildPath(webhooksDir, "Get-SimHub-Data.ps1")

stopCommand = "powershell.exe -ExecutionPolicy Bypass -NoLogo -NonInteractive -Command " & Chr(34) & "& { & '" & scriptPath & "' -Stop -DataDir '" & dataDir & "' *>&1 | Out-File -FilePath '" & logPath & "' -Append -Encoding utf8 }" & Chr(34)

objShell.Run stopCommand, 0, True

Set objShell = Nothing
Set objFSO = Nothing
