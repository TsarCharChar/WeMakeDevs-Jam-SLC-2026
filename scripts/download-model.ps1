$ErrorActionPreference = 'Stop'

$filename = 'ggml-large-v3-turbo-q5_0.bin'
$revision = '5359861c739e955e79d9a303bcbc70fb988958b1'
$expectedHash = '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2'
$expectedBytes = 574041195
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
$curl = Get-Command $curlName -CommandType Application -ErrorAction Stop | Select-Object -First 1
New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
Write-Output "Downloading $filename (574 MB)..."
& $curl.Source --location --fail --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 120 --output $partial $url
if ($LASTEXITCODE -ne 0) {
    throw 'Model download failed. Rerun this script to try again.'
}
if (-not (Test-ModelFile $partial)) {
    throw "Downloaded model failed size or SHA-256 verification: $partial. Rerun this script to download again."
}
Move-Item -LiteralPath $partial -Destination $target -Force
Write-Output "Model installed; SHA-256 verified: $target"
