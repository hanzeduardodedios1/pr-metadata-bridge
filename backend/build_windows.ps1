# Build a single-file, no-console Windows executable for the FastAPI backend.
# Run from PowerShell, from the backend folder:
#   .\build_windows.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Get-Command pyinstaller -ErrorAction SilentlyContinue)) {
    Write-Error "PyInstaller not found. Install with: pip install pyinstaller"
}

pyinstaller --clean --noconfirm pr-metadata-bridge.spec

Write-Host "Output: $PSScriptRoot\dist\pr-metadata-bridge-api.exe"
