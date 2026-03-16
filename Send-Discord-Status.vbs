Set objShell = CreateObject("Wscript.shell")

' Define the command to run the PowerShell script
' -ExecutionPolicy Bypass allows the script to run even if restricted by group policy
' -File specifies the script to run
' The "" around ".\YourScript.ps1" handle spaces in the path if necessary
strCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoLogo -NonInteractive -File " & Chr(34) & ".\Send-Discord-Status.ps1" & Chr(34)

' Run the command
' The second parameter (0) hides the console window
objShell.Run strCommand, 0

Set objShell = Nothing
