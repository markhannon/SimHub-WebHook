# 
# Install latests files to simhub
#

param (
    [switch]$dashboards = $false,
    [switch]$overlays = $false
)

$SettingsObject = Get-Content -Path settings.json | ConvertFrom-Json

Set-PSDebug -Trace 0

$sections = "batch", "json", "powershell", "vbscript"
foreach ($section in $sections) {
    Write-Host "Installing $section files..."
    $collection = $SettingsObject.$section
    Write-Host "Found $($collection.Count) items in $section section."
    foreach ($item in $collection) {
        $src = $SettingsObject.src
        $dst = $SettingsObject.dst
        $fileName = $item.name
        robocopy `
            $src\ `
            $dst\ `
            "$fileName" `
            /xd ".git" `
            /xd ".gitignore" `
            /xd ".vscode" `
            /mir
    }
}