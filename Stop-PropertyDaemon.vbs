Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get the directory where this script is located
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
daemonScript = objFSO.BuildPath(scriptDir, "SimHub-PropertyServer-Daemon.ps1")

' Stop the daemon gracefully
' The daemon will respond to the stop signal within 5 seconds
stopCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoLogo -NonInteractive -File """ & daemonScript & """ -Command Stop"

' Run the command and wait for completion
objShell.Run stopCommand, 0, True

Set objShell = Nothing
Set objFSO = Nothing
