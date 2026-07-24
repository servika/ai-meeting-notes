; Inno Setup script for AI Meeting Notes (Windows).
; Built by build-app.ps1 when ISCC.exe is on PATH:
;   ISCC /DMyAppVersion=0.1.0 /DMyAppDir=publish\app /Opublish scripts\installer.iss

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyAppDir
  #define MyAppDir "..\publish\app"
#endif

[Setup]
; Stable AppId - lets Inno recognise a previous install for upgrades/uninstall.
; NEVER change this GUID once shipped, or upgrades stop being detected. It's also
; hard-coded (without the outer braces) in [Code] below to read the uninstaller;
; keep the two in sync.
AppId={{2B67AD51-00C0-41DF-8AAF-3E73F3FEE619}
AppName=AI Meeting Notes
AppVersion={#MyAppVersion}
AppPublisher=Serg Bataev
DefaultDirName={autopf}\AI Meeting Notes
DefaultGroupName=AI Meeting Notes
; Upgrades land in the same folder with the same task selections as before.
UsePreviousAppDir=yes
UsePreviousTasks=yes
UninstallDisplayIcon={app}\MeetingNotes.App.exe
SetupIconFile={#MyAppDir}\app.ico
OutputBaseFilename=AI-Meeting-Notes-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
; Use Restart Manager to close a running instance during an in-place upgrade,
; so locked exe/DLLs in {app} don't fail the install.
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#MyAppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AI Meeting Notes"; Filename: "{app}\MeetingNotes.App.exe"; IconFilename: "{app}\app.ico"
Name: "{autodesktop}\AI Meeting Notes"; Filename: "{app}\MeetingNotes.App.exe"; IconFilename: "{app}\app.ico"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\MeetingNotes.App.exe"; Description: "Launch AI Meeting Notes"; Flags: nowait postinstall skipifsilent

[Code]
const
  // Uninstall registry key = "{AppId}_is1". Keep the GUID in sync with [Setup].
  UninstallKey =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{2B67AD51-00C0-41DF-8AAF-3E73F3FEE619}_is1';

// Path to the previous install's uninstaller (unins000.exe), unquoted, or '' if
// there's no prior install. Checks both registry views + per-user, so a 32- or
// 64-bit or per-user prior install is still found.
function OldUninstaller(): String;
var
  cmd: String;
begin
  cmd := '';
  if not RegQueryStringValue(HKLM, UninstallKey, 'UninstallString', cmd) then
    if not RegQueryStringValue(HKLM64, UninstallKey, 'UninstallString', cmd) then
      RegQueryStringValue(HKCU, UninstallKey, 'UninstallString', cmd);
  Result := RemoveQuotes(cmd);
end;

// Before any new files are copied, uninstall the previous version so orphaned
// files from older builds don't linger. This only removes what the installer put
// in {app} plus its registry entries - user config, downloaded whisper models and
// the notes vault all live outside {app} (in %APPDATA%\MeetingNotes and the chosen
// vault) and are untouched, so a reinstall/upgrade comes back fully configured.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  uninst: String;
  code, i: Integer;
begin
  Result := '';
  uninst := OldUninstaller();
  if (uninst = '') or (not FileExists(uninst)) then
    Exit;

  if Exec(uninst, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_HIDE,
          ewWaitUntilTerminated, code) then
  begin
    // unins000.exe relaunches itself from %TEMP% and returns early, so poll (up to
    // ~10s) until the original uninstaller is actually gone before we lay down the
    // new files - otherwise the async cleanup could delete files we just wrote.
    for i := 1 to 100 do
    begin
      if not FileExists(uninst) then
        Break;
      Sleep(100);
    end;
  end;
end;