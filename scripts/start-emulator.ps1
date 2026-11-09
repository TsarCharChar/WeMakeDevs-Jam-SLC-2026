# This machine's SwiftShader renderer crashes qemu during Flutter rendering.
# Use the host GPU and cold boot instead of restoring a software-rendered snapshot.
# After boot: flutter run --release -d emulator-5554 -t lib/main.dart --no-resident
param(
    [string]$Avd = 'Medium_Phone_API_37.0',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\sdk"
)

$ErrorActionPreference = 'Stop'
Start-Process -FilePath (Join-Path $AndroidSdk 'emulator\emulator.exe') `
    -ArgumentList '-avd', $Avd, '-no-snapshot', '-gpu', 'host', '-memory', '4096', '-cores', '4' `
    -WindowStyle Hidden
