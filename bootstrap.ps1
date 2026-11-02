<#
.SYNOPSIS
    WRITE. One-command Vorterm launcher: downloads the latest Vorterm, unpacks it and opens the installer.

.DESCRIPTION
    Downloads the main branch zip from GitHub to %LOCALAPPDATA%\Vorterm\app (replacing only
    that folder: logs, assets and your LAB are elsewhere and are not touched), unblocks the
    files and starts the Vorterm window. Nothing is installed until you press INSTALL.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force; [Net.ServicePointManager]::SecurityProtocol=3072; $f="$env:TEMP\vorterm-bootstrap.ps1"; irm https://raw.githubusercontent.com/4leX-42/Vorterm/main/bootstrap.ps1 -OutFile $f; & $f

.NOTES
    Context: user. No admin rights needed. Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$base = Join-Path $env:LOCALAPPDATA 'Vorterm'
$app  = Join-Path $base 'app'
$tmp  = Join-Path $env:TEMP ('vorterm-dl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$zip  = Join-Path $tmp 'vorterm.zip'
$url  = "https://github.com/4leX-42/Vorterm/archive/refs/heads/$Branch.zip"

try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Write-Host "Downloading Vorterm ($Branch)..." -ForegroundColor DarkYellow
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'setup_terminal.ps1') } | Select-Object -First 1
    if (-not $src) { throw "setup_terminal.ps1 not found in $url" }

    New-Item -ItemType Directory -Path $base -Force | Out-Null
    if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
    Move-Item -LiteralPath $src.FullName -Destination $app
    Get-ChildItem -LiteralPath $app -Recurse -File | Unblock-File
    Write-Host "Vorterm ready in $app" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Same launch as INSTALAR.bat: Windows PowerShell 5.1 (WPF needs STA), window only.
$setup = Join-Path $app 'setup_terminal.ps1'
Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -ArgumentList "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$setup`""
Write-Host 'Vorterm window opening...' -ForegroundColor Green
