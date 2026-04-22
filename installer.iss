[Setup]
AppId={{9FA8A2AA-8E80-4E5D-BD95-C66A57B3884A}
AppName=CaptionFast
AppVersion=1.0.0
AppPublisher=CaptionFast
DefaultDirName={autopf}\CaptionFast
DefaultGroupName=CaptionFast
DisableProgramGroupPage=yes
OutputDir=Installers
OutputBaseFilename=CaptionFast-Setup-1.0.0
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "frontend\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CaptionFast"; Filename: "{app}\frontend.exe"
Name: "{autodesktop}\CaptionFast"; Filename: "{app}\frontend.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\frontend.exe"; Description: "{cm:LaunchProgram,CaptionFast}"; Flags: nowait postinstall skipifsilent
