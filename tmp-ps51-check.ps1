$scriptPath = 'C:\Program Files (x86)\SimHub\Webhooks\SimHub-PropertyServer-Daemon.ps1'

Write-Output '=== PARSE ==='
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object {
        "{0}:{1} {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
    }
}
else {
    'PARSE_OK'
}

Write-Output '=== TAIL LINES ==='
$lines = Get-Content -Path $scriptPath
for ($i = 650; $i -le 670; $i++) {
    if ($i -le $lines.Count) {
        "{0:D4}: {1}" -f $i, $lines[$i - 1]
    }
}

Write-Output '=== RUN -STATUS ==='
Set-Location 'C:\Program Files (x86)\SimHub\Webhooks'
try {
    & .\SimHub-PropertyServer-Daemon.ps1 -Status
    "EXITCODE=$LASTEXITCODE"
}
catch {
    $_ | Out-String
}
