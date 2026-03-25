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

stopCommand = "powershell.exe -ExecutionPolicy Bypass -NoLogo -NonInteractive -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34) & " -Stop -DataDir " & Chr(34) & dataDir & Chr(34)

Set wmiService = GetObject("winmgmts:\\.\root\cimv2")
Set startupConfig = wmiService.Get("Win32_ProcessStartup").SpawnInstance_()
startupConfig.ShowWindow = 0
Set processClass = wmiService.Get("Win32_Process")
createResult = processClass.Create(stopCommand, Null, startupConfig, processId)

If createResult <> 0 Then
	Set logFile = objFSO.OpenTextFile(logPath, 8, True)
	logFile.WriteLine "[" & Now & "] [VBS] ERROR Win32_Process.Create failed (code " & createResult & ")"
	logFile.WriteLine "[" & Now & "] [VBS] COMMAND " & stopCommand
	logFile.Close
	Set logFile = Nothing
End If

Set processClass = Nothing
Set startupConfig = Nothing
Set wmiService = Nothing
Set objFSO = Nothing
