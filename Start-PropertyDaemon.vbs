Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get the directory where this script is located
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
daemonScript = objFSO.BuildPath(scriptDir, "SimHub-PropertyServer-Daemon.ps1")

' Start the daemon in the background
' Uses WindowStyle 0 to run hidden
' Uses Start /B (batch mode) to avoid blocking
startCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoLogo -NonInteractive -File """ & daemonScript & """ -Command Start"

' Run the command in background (async)
objShell.Run startCommand, 0, False

' Wait a moment for daemon to initialize
WScript.Sleep 1000

Set objShell = Nothing
Set objFSO = Nothing
