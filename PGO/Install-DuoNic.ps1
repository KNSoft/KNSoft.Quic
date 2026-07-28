<#
.SYNOPSIS
    Installs and validates the DuoNic adapter pair used by PGO training.
#>

[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$MsQuicRoot = Join-Path $RepoRoot "msquic"
$PrepareMachine = Join-Path $MsQuicRoot "scripts\prepare-machine.ps1"
if (!(Test-Path $PrepareMachine)) {
    throw "The MsQuic submodule is missing."
}

$Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($Architecture -eq [Runtime.InteropServices.Architecture]::Arm64) {
    & $PrepareMachine -InstallSigningCertificates
    $SetupPath = Join-Path $MsQuicRoot "artifacts\corenet-ci-main\vm-setup"
    Push-Location (Join-Path $SetupPath "duonic\arm64")
    try {
        .\duonic.ps1 -Install
    } finally {
        Pop-Location
    }

    & (Join-Path $SetupPath "tcprssseed.exe") set aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55aa55
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure the DuoNic RSS seed."
    }
} elseif ($Architecture -eq [Runtime.InteropServices.Architecture]::X64) {
    & $PrepareMachine -InstallDuoNic
} else {
    throw "DuoNic installation is not supported on a $Architecture host."
}

$Adapters = @(Get-NetAdapter -Name "duo?" -ErrorAction Stop)
if ($Adapters.Count -lt 2 -or @($Adapters | Where-Object Status -ne "Up").Count -ne 0) {
    throw "DuoNic adapter pair is unavailable."
}
