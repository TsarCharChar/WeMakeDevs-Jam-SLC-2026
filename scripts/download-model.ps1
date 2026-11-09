$ErrorActionPreference = 'Stop'

$filename = 'ggml-base.en-q5_1.bin'
$revision = '5359861c739e955e79d9a303bcbc70fb988958b1'
$expectedHash = '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f'
$expectedBytes = 59721011
$repoRoot = Split-Path -Parent $PSScriptRoot
$modelDir = Join-Path $repoRoot 'assets/models'
$target = Join-Path $modelDir $filename
$partial = "$target.partial"
$url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/$revision/${filename}?download=true"

function Test-ModelFile([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $expectedBytes) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedHash
}

if (Test-ModelFile $target) {
    Write-Output "Model already installed; SHA-256 verified: $target"
    exit 0
}

$curlName = if ($env:OS -eq 'Windows_NT') { 'curl.exe' } else { 'curl' }
$curl = Get-Command $curlName -CommandType Application -ErrorAction Stop
New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
Write-Output "Downloading $filename (57 MB)..."
& $curl.Source --location --fail --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 120 --output $partial $url
if ($LASTEXITCODE -ne 0) {
    throw 'Model download failed. Rerun this script to try again.'
}
if (-not (Test-ModelFile $partial)) {
    throw "Downloaded model failed size or SHA-256 verification: $partial. Rerun this script to download again."
}
Move-Item -LiteralPath $partial -Destination $target -Force
Write-Output "Model installed; SHA-256 verified: $target"
