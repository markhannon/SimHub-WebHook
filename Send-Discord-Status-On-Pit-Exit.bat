@ECHO OFF
SET ThisScriptsDirectory=%~dp0
SET PowerShellScriptPath=%ThisScriptsDirectory%Send-Discord-Status.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PowerShellScriptPath%" -Extra "Exiting Pits"

