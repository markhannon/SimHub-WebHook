
#include "SimHub-WebHook-Installer-Version.iss"
; SimHub-WebHook-Installer.iss
; Inno Setup script for SimHub WebHook deployment
; Prompts for SimHub directory, supports upgrades, prompts for config overwrites, and includes uninstaller

[Setup]
AppName=SimHub WebHook Integration
AppVersion={#MyAppVersion}
DefaultDirName={code:GetSimHubDir}
DefaultGroupName=SimHub WebHook
UninstallDisplayIcon={app}\Webhooks\Discord.json
OutputDir=dist
OutputBaseFilename=SimHub-WebHook-Installer-{#MyAppVersion}
Compression=lzma
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Code]
var
  SimHubDirPage: TInputDirWizardPage;

function GetSimHubDir(Default: String): String;
begin
  Result := ExpandConstant('C:\Program Files (x86)\SimHub');
end;

procedure InitializeWizard;
begin
  SimHubDirPage := CreateInputDirPage(wpSelectDir,
    'SimHub Directory',
    'Where is SimHub installed?',
    'Select the root folder of your SimHub installation. The installer will copy files to ShellMacros and Webhooks.',
    False, '');
  SimHubDirPage.Add('C:\Program Files (x86)\SimHub');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  if CurPageID = SimHubDirPage.ID then
    WizardForm.DirEdit.Text := SimHubDirPage.Values[0];
  Result := True;
end;

[Dirs]
Name: "{code:GetSimHubDir}\ShellMacros"; Flags: uninsalwaysuninstall
Name: "{code:GetSimHubDir}\Webhooks"; Flags: uninsalwaysuninstall

[Files]
; VBScript files to ShellMacros
Source: "Send-Discord-Message-Incident.vbs"; DestDir: "{code:GetSimHubDir}\ShellMacros"; Flags: ignoreversion uninsneveruninstall
Source: "Send-Discord-Message-PittingSoon.vbs"; DestDir: "{code:GetSimHubDir}\ShellMacros"; Flags: ignoreversion uninsneveruninstall
Source: "Send-Discord-Message-StatusUpdate.vbs"; DestDir: "{code:GetSimHubDir}\ShellMacros"; Flags: ignoreversion uninsneveruninstall
Source: "Get-SimHub-Data-Start.vbs"; DestDir: "{code:GetSimHubDir}\ShellMacros"; Flags: ignoreversion uninsneveruninstall
Source: "Get-SimHub-Data-Stop.vbs"; DestDir: "{code:GetSimHubDir}\ShellMacros"; Flags: ignoreversion uninsneveruninstall

; PowerShell and JSON files to Webhooks
Source: "Format-Csv-Data.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Get-SimHub-Data.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Install-To-SimHub.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Sample-SimHub-Data.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Send-Discord-Data.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Send-Discord-Message.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "SimHub-PropertyServer-Daemon.ps1"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Discord.json"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion promptifolder uninsneveruninstall; Check: ShouldOverwriteConfig('Discord.json')
Source: "Events.json"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion promptifolder uninsneveruninstall; Check: ShouldOverwriteConfig('Events.json')
Source: "Properties.json"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion uninsneveruninstall
Source: "Simhub.json"; DestDir: "{code:GetSimHubDir}\Webhooks"; Flags: ignoreversion promptifolder uninsneveruninstall; Check: ShouldOverwriteConfig('Simhub.json')

[UninstallDelete]
Type: files; Name: "{code:GetSimHubDir}\ShellMacros\Send-Discord-Message-Incident.vbs"
Type: files; Name: "{code:GetSimHubDir}\ShellMacros\Send-Discord-Message-PittingSoon.vbs"
Type: files; Name: "{code:GetSimHubDir}\ShellMacros\Send-Discord-Message-StatusUpdate.vbs"
Type: files; Name: "{code:GetSimHubDir}\ShellMacros\Get-SimHub-Data-Start.vbs"
Type: files; Name: "{code:GetSimHubDir}\ShellMacros\Get-SimHub-Data-Stop.vbs"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Format-Csv-Data.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Get-SimHub-Data.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Install-To-SimHub.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Sample-SimHub-Data.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Send-Discord-Data.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Send-Discord-Message.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\SimHub-PropertyServer-Daemon.ps1"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Properties.json"
Type: files; Name: "{code:GetSimHubDir}\Webhooks\Simhub.json"

[Code]
function ShouldOverwriteConfig(FileName: String): Boolean;
begin
  if FileExists(ExpandConstant('{code:GetSimHubDir}\Webhooks\') + FileName) then
    Result := MsgBox('Overwrite ' + FileName + '? This will replace your existing configuration.', mbConfirmation, MB_YESNO) = idYes
  else
    Result := True;
end;
