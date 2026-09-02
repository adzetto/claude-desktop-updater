<#
.SYNOPSIS
    Compiles claude-desktop-updater.ps1 into a standalone executable with
    ps2exe and optionally installs it on the user PATH.

.EXAMPLE
    .\build.ps1                 # dist\claude-desktop-updater.exe
    .\build.ps1 -Install        # also copies to %ProgramData%\claude-desktop-updater and adds it to PATH
#>
[CmdletBinding()]
param([switch]$Install)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src  = Join-Path $root 'claude-desktop-updater.ps1'
$dist = Join-Path $root 'dist'
$exe  = Join-Path $dist 'claude-desktop-updater.exe'

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "Installing ps2exe module (CurrentUser scope)"
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) { $errors | ForEach-Object { Write-Error "line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }

$version = (Select-String -Path $src -Pattern "^\`$Script:Version\s*=\s*'([0-9.]+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
New-Item -ItemType Directory -Path $dist -Force | Out-Null
Get-Process -Name 'claude-desktop-updater' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Invoke-ps2exe -inputFile $src -outputFile $exe `
    -title 'Claude Desktop Updater' -description 'Repairs and updates Claude Desktop on Windows' `
    -company 'adzetto' -product 'claude-desktop-updater' -copyright 'MIT License' `
    -version "$version.0" -iconFile (Join-Path $root 'assets\icon.ico') -ErrorAction SilentlyContinue

if (-not (Test-Path $exe)) {
    # retry without icon (ps2exe fails silently on a missing icon on some versions)
    Invoke-ps2exe -inputFile $src -outputFile $exe -title 'Claude Desktop Updater' `
        -description 'Repairs and updates Claude Desktop on Windows' -company 'adzetto' -version "$version.0"
}
Write-Host "Built $exe ($((Get-Item $exe).Length) bytes, v$version)"

if ($Install) {
    $target = Join-Path $env:ProgramData 'claude-desktop-updater'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item $exe (Join-Path $target 'claude-desktop-updater.exe') -Force
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $target) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $target), 'User')
        Write-Host "Added $target to the user PATH (open a new terminal to use it)"
    }
    Write-Host "Installed: run 'claude-desktop-updater' from any terminal"
}
