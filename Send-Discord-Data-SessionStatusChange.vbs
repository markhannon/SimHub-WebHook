Set objShell = CreateObject("Wscript.shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Define the command to run the PowerShell script
' -ExecutionPolicy Bypass allows the script to run even if restricted by group policy
' -File specifies the script to run
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
scriptPath = objFSO.BuildPath(scriptDir, "Send-Discord-Data.ps1")

sessionEndCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoLogo -NonInteractive -File " & Chr(34) & scriptPath & Chr(34) & " -Status"

' Run session-end event command and wait for completion
objShell.Run sessionEndCommand, 0, True

Set objShell = Nothing
Set objFSO = Nothing
