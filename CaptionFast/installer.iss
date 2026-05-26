#define MyAppName "CaptionFast"
#define MyAppVersion "1.0.0"
#define MyAppExeName "CaptionFast.exe"
#define MyAppIconName "app_icon.ico"

[Setup]
AppId={{9FA8A2AA-8E80-4E5D-BD95-C66A57B3884A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=CaptionFast
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Installers
OutputBaseFilename=CaptionFast-Setup-{#MyAppVersion}
SetupIconFile=assets\icon\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Main Flutter executable
Source: "build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
; ExifTool binary
Source: "build\windows\x64\runner\Release\exiftool.exe"; DestDir: "{app}"; Flags: ignoreversion
; ExifTool Engine Folder (CRITICAL)
Source: "build\windows\x64\runner\Release\exiftool_files\*"; DestDir: "{app}\exiftool_files"; Flags: ignoreversion recursesubdirs createallsubdirs
; Flutter DLLs
Source: "build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
; Data folder (Flutter assets)
Source: "build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent