<#
.SYNOPSIS
    Builds the upstream SecNetPerf binaries used by PGO training.

.DESCRIPTION
    Uses the latest Visual Studio installation on the current machine and stores
    architecture- and CRT-specific tools under PGO\Temp\Tools.
#>

[CmdletBinding()]
param (
    [ValidateSet("x86", "x64", "arm64", "arm64ec")]
    [string[]]$Architecture = @(),

    [ValidateSet("MT", "MD")]
    [string[]]$Runtime = @("MT", "MD")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$MsQuicRoot = Join-Path $RepoRoot "msquic"
$TempRoot = Join-Path $PSScriptRoot "Temp"
if (@($Architecture).Count -eq 0) {
    $Architecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) {
        @("arm64", "arm64ec")
    } else {
        @("x86", "x64")
    }
}

function Get-RunnerArchitecture([string]$Arch) {
    if ($Arch -eq "arm64ec") { return "x64" }
    return $Arch
}

$VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $VsWhere)) {
    throw "vswhere.exe was not found."
}
$VisualStudio = & $VsWhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if (!$VisualStudio) {
    throw "Visual Studio with MSBuild was not found."
}
$CMakeBin = Join-Path $VisualStudio "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
$BuildScript = Join-Path $MsQuicRoot "scripts\build.ps1"
if (!(Test-Path $BuildScript) -or !(Test-Path $CMakeBin)) {
    throw "The MsQuic submodule or Visual Studio CMake installation is missing."
}

$OriginalPath = $env:PATH
try {
    $env:PATH = "$CMakeBin;$OriginalPath"
    foreach ($Arch in $Architecture) {
        $RunnerArch = Get-RunnerArchitecture $Arch
        foreach ($Crt in $Runtime) {
            Write-Host "Building SecNetPerf for $Arch/$Crt"
            $BuildParameters = @{
                Config = "Release"
                Arch = $RunnerArch
                Tls = "schannel"
                DisableTest = $true
                DisableTools = $true
                Parallel = [Environment]::ProcessorCount
            }
            if ($Crt -eq "MD") {
                $BuildParameters.DynamicCRT = $true
            } else {
                $BuildParameters.StaticCRT = $true
            }

            & $BuildScript @BuildParameters
            if ($LASTEXITCODE -ne 0) {
                throw "SecNetPerf build failed for $Arch/$Crt."
            }

            $SourceDirectory = Join-Path $MsQuicRoot "artifacts\bin\windows\$($RunnerArch)_Release_schannel"
            $ToolDirectory = Join-Path $TempRoot "Tools\$Arch\$Crt"
            $Executable = Join-Path $SourceDirectory "secnetperf.exe"
            $Dll = Join-Path $SourceDirectory "msquic.dll"
            if (!(Test-Path $Executable) -or !(Test-Path $Dll)) {
                throw "SecNetPerf build outputs are missing for $Arch/$Crt."
            }

            New-Item -ItemType Directory -Force $ToolDirectory | Out-Null
            Copy-Item $Executable, $Dll $ToolDirectory -Force
            foreach ($Name in @("secnetperf.pdb", "msquic.pdb")) {
                $Source = Join-Path $SourceDirectory $Name
                if (Test-Path $Source) {
                    Copy-Item $Source $ToolDirectory -Force
                }
            }
        }
    }
} finally {
    $env:PATH = $OriginalPath
}

Write-Host "SecNetPerf build completed. Tools are under $TempRoot\Tools."
