; Inno Setup script for the Windows desktop build.
; Compiled in CI:
;   ISCC /DAppVersion=<pubspec version> packaging\windows\installer.iss
; Expects the release build at build\windows\x64\runner\Release.

#define AppName "惠窗中小学端"
#define AppExeName "huichuang_basic.exe"

[Setup]
AppId={{7C1A5B62-9D4E-4F2B-8C3A-6E5D1F0A2B47}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=huichuang_basic contributors
AppPublisherURL=https://github.com/bluseliu50/huichuang_basic
DefaultDirName={autopf}\huichuang_basic
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\
OutputBaseFilename=huichuang_basic-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
; Non-commercial redistribution only (CC BY-NC-SA 4.0).
LicenseFile=..\..\LICENSE

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
