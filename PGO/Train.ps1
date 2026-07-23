<#
.SYNOPSIS
    Trains and validates KNSoft.Quic PGO profiles using prebuilt SecNetPerf tools.

.DESCRIPTION
    Uses the latest Visual Studio installation on the current machine. Temporary
    tools, PGC files, logs, binaries, and benchmark results are kept under
    PGO\Temp. Final PGD files and manifests are written under PGO\<arch>.
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
$Solution = Join-Path $RepoRoot "KNSoft.Quic.slnx"
$TempRoot = Join-Path $PSScriptRoot "Temp"
$ConfigurationFile = Join-Path $PSScriptRoot "Training.json"
$ProfileRoot = $PSScriptRoot
if (@($Architecture).Count -eq 0) {
    $Architecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) {
        @("arm64", "arm64ec")
    } else {
        @("x86", "x64")
    }
}

function Get-OptionalProperty([object]$Object, [string]$Name, [object]$DefaultValue) {
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $DefaultValue
    }
    return $Property.Value
}

function Get-VisualStudio {
    $VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path $VsWhere)) {
        throw "vswhere.exe was not found."
    }

    $InstallPath = & $VsWhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if (!$InstallPath) {
        throw "Visual Studio with MSBuild was not found."
    }

    $VCToolsVersion = (Get-Content (Join-Path $InstallPath "VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt") -Raw).Trim()
    $ToolsRoot = Join-Path $InstallPath "VC\Tools\MSVC\$VCToolsVersion"
    $HostDirectory = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) {
        "Hostarm64"
    } else {
        "Hostx64"
    }
    [pscustomobject]@{
        InstallPath = $InstallPath
        InstallationVersion = & $VsWhere -latest -products * -requires Microsoft.Component.MSBuild -property installationVersion
        VCToolsVersion = $VCToolsVersion
        ToolsRoot = $ToolsRoot
        MSBuild = Join-Path $InstallPath "MSBuild\Current\Bin\MSBuild.exe"
        HostDirectory = $HostDirectory
    }
}

function Assert-HostSupport([string]$Arch) {
    $HostArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($HostArch -notin @("x64", "arm64")) {
        throw "Unsupported training host architecture: $HostArch"
    }
    $SupportedArchitectures = if ($HostArch -eq "arm64") { @("arm64", "arm64ec") } else { @("x86", "x64") }
    if ($Arch -notin $SupportedArchitectures) {
        throw "$Arch training is not supported on a native $HostArch host."
    }
}

function Get-Platform([string]$Arch) {
    if ($Arch -eq "arm64ec") { return "ARM64EC" }
    return $Arch
}

function Get-OutputArchitecture([string]$Arch) {
    if ($Arch -eq "arm64") { return "ARM64" }
    if ($Arch -eq "arm64ec") { return "ARM64EC" }
    return $Arch
}

function Get-Configuration([string]$Crt) {
    if ($Crt -eq "MD") { return "ReleaseMD" }
    return "Release"
}

function Get-PgoTools([object]$VisualStudio, [string]$Arch) {
    $ManagerArch = if ($Arch -eq "arm64ec") { "arm64" } else { $Arch }
    $Manager = Join-Path $VisualStudio.ToolsRoot "bin\$($VisualStudio.HostDirectory)\$ManagerArch\pgomgr.exe"
    if (!(Test-Path $Manager)) {
        $Manager = Join-Path $VisualStudio.ToolsRoot "bin\Hostx64\$ManagerArch\pgomgr.exe"
    }

    $RuntimeCandidates = if ($Arch -eq "x86") {
        @("bin\Hostx86\x86\pgort140.dll", "bin\Hostx64\x86\pgort140.dll")
    } elseif ($Arch -in @("arm64", "arm64ec")) {
        @("bin\arm64\pgort140.dll", "bin\Hostarm64\arm64\pgort140.dll", "bin\Hostx64\arm64\pgort140.dll")
    } else {
        @("bin\Hostx64\x64\pgort140.dll")
    }
    $PgoRuntime = $RuntimeCandidates |
        ForEach-Object { Join-Path $VisualStudio.ToolsRoot $_ } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

    if (!(Test-Path $Manager) -or !$PgoRuntime) {
        throw "PGO tools for $Arch were not found in $($VisualStudio.ToolsRoot)."
    }
    [pscustomobject]@{ Manager = $Manager; Runtime = $PgoRuntime }
}

function Invoke-MSBuild(
    [object]$VisualStudio,
    [string]$Arch,
    [string]$Crt,
    [string]$Mode,
    [string]$CustomPgd = ""
) {
    $Arguments = @(
        $Solution,
        "/t:Rebuild",
        "/m",
        "/p:Configuration=$(Get-Configuration $Crt)",
        "/p:Platform=$(Get-Platform $Arch)",
        "/p:KNSoftQuicPGOMode=$Mode",
        "/v:minimal",
        "/nologo"
    )
    if ($CustomPgd) {
        $Arguments += "/p:KNSoftQuicCustomPGD=$CustomPgd"
    }

    $Output = @(& $VisualStudio.MSBuild @Arguments 2>&1)
    $Output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "KNSoft.Quic $Mode build failed for $Arch/$Crt."
    }
    return ,$Output
}

function Get-SecNetPerf([string]$Arch, [string]$Crt) {
    $ToolDirectory = Join-Path $TempRoot "Tools\$Arch\$Crt"
    $Executable = Join-Path $ToolDirectory "secnetperf.exe"
    $UpstreamDll = Join-Path $ToolDirectory "msquic.dll"

    if (!(Test-Path $Executable) -or !(Test-Path $UpstreamDll)) {
        throw "SecNetPerf tools for $Arch/$Crt are missing. Run PGO\Build-SecNetPerf.ps1 first."
    }
    [pscustomobject]@{
        Directory = $ToolDirectory
        Executable = $Executable
        UpstreamDll = $UpstreamDll
    }
}

function New-HardLink([string]$Path, [string]$Target) {
    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    New-Item -ItemType HardLink -Path $Path -Target $Target | Out-Null
}

function Initialize-RunDirectory(
    [string]$Root,
    [string]$Executable,
    [string]$ClientDll,
    [string]$ServerDll,
    [string]$PgoRuntime = ""
) {
    if (Test-Path $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
    $ClientDirectory = Join-Path $Root "client"
    $ServerDirectory = Join-Path $Root "server"
    New-Item -ItemType Directory -Force $ClientDirectory, $ServerDirectory | Out-Null

    New-HardLink (Join-Path $ClientDirectory "secnetperf.exe") $Executable
    New-HardLink (Join-Path $ServerDirectory "secnetperf.exe") $Executable
    Copy-Item $ClientDll (Join-Path $ClientDirectory "msquic.dll") -Force
    Copy-Item $ServerDll (Join-Path $ServerDirectory "msquic.dll") -Force
    if ($PgoRuntime) {
        Copy-Item $PgoRuntime (Join-Path $ClientDirectory "pgort140.dll") -Force
        Copy-Item $PgoRuntime (Join-Path $ServerDirectory "pgort140.dll") -Force
    }

    [pscustomobject]@{
        Client = $ClientDirectory
        Server = $ServerDirectory
    }
}

function Wait-ServerReady([Diagnostics.Process]$Process, [string]$OutputFile) {
    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($Stopwatch.ElapsedMilliseconds -lt 15000) {
        if ($Process.HasExited) {
            throw "SecNetPerf server exited before it became ready."
        }
        if ((Test-Path $OutputFile) -and (Get-Content $OutputFile -Raw -ErrorAction SilentlyContinue) -match "Started!") {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for the SecNetPerf server."
}

function Stop-Server([Diagnostics.Process]$Process) {
    $Socket = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $Endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 9999)
    $ShutdownPacket = [byte[]](0x57, 0xe6, 0x15, 0xff, 0x26, 0x4f, 0x0e, 0x57, 0x88, 0xab, 0x07, 0x96, 0xb2, 0x58, 0xd1, 0x1c)
    try {
        for ($Attempt = 0; $Attempt -lt 10 -and !$Process.HasExited; $Attempt++) {
            [void]$Socket.Send($ShutdownPacket, $ShutdownPacket.Length, $Endpoint)
            [void]$Process.WaitForExit(1000)
        }
    } finally {
        $Socket.Dispose()
    }
    if (!$Process.HasExited) {
        $Process.Kill()
        $Process.WaitForExit()
        throw "SecNetPerf server did not stop cleanly."
    }
    if ($Process.ExitCode -ne 0) {
        throw "SecNetPerf server failed with exit code $($Process.ExitCode)."
    }
}

function Get-Scenario([object]$Configuration, [string]$Name) {
    $Scenario = $Configuration.scenarios | Where-Object name -eq $Name | Select-Object -First 1
    if ($null -eq $Scenario) {
        throw "Scenario '$Name' was not found in $ConfigurationFile."
    }
    return $Scenario
}

function Resolve-Scenario([object]$Configuration, [object]$Specification) {
    if ($Specification -is [string]) {
        return Get-Scenario $Configuration $Specification
    }

    $Scenario = Get-Scenario $Configuration ([string]$Specification.name)
    $Properties = [ordered]@{}
    foreach ($Property in $Scenario.PSObject.Properties) {
        $Properties[$Property.Name] = $Property.Value
    }
    foreach ($Property in $Specification.PSObject.Properties) {
        $Properties[$Property.Name] = $Property.Value
    }
    return [pscustomobject]$Properties
}

function Get-NetworkProfile([object]$Configuration, [string]$Name) {
    $Profile = $Configuration.emulatedNetwork.profiles | Where-Object name -eq $Name | Select-Object -First 1
    if ($null -eq $Profile) {
        throw "Network profile '$Name' was not found in $ConfigurationFile."
    }
    return $Profile
}

function New-NetworkConfiguration([object]$Configuration, [object]$Profile) {
    [pscustomobject]@{
        name = $Profile.name
        clientAddress = Get-OptionalProperty $Profile "clientAddress" $Configuration.emulatedNetwork.clientAddress
        serverAddress = Get-OptionalProperty $Profile "serverAddress" $Configuration.emulatedNetwork.serverAddress
        pacing = $Profile.pacing
        congestionControl = $Profile.congestionControl
    }
}

function Get-ScenarioDuration([object]$Scenario) {
    return [int]$Scenario.durationSeconds
}

function Get-ScenarioWeight([object]$Scenario) {
    $Weight = [int](Get-OptionalProperty $Scenario "weight" 1)
    if ($Weight -lt 1) {
        throw "Scenario weight must be positive: $($Scenario.name)."
    }
    return $Weight
}

function Get-ScenarioArguments([object]$Scenario, [object]$Network, [int]$Duration) {
    $Target = if ($null -eq $Network) { "localhost" } else { [string]$Network.serverAddress }
    $WatchdogTimeout = [Math]::Max(60000, ($Duration + 60) * 1000)
    $Arguments = @(
        "-target:$Target",
        "-scenario:$($Scenario.preset)",
        "-io:iocp",
        "-tcp:0",
        "-trimout",
        "-watchdog:$WatchdogTimeout"
    )
    if ($null -ne $Network) {
        $Arguments += "-bind:$($Network.clientAddress)"
        $Arguments += "-pacing:$([int][bool]$Network.pacing)"
        $Arguments += "-cc:$($Network.congestionControl)"
    }

    $Connections = [int](Get-OptionalProperty $Scenario "connections" 0)
    $Streams = [int](Get-OptionalProperty $Scenario "streams" 0)
    if ($Connections -gt 0) { $Arguments += "-conns:$Connections" }
    if ($Streams -gt 0) { $Arguments += "-streams:$Streams" }

    if ($Scenario.preset -eq "upload") {
        return $Arguments + "-upload:$($Duration)s"
    }
    if ($Scenario.preset -eq "download") {
        return $Arguments + "-download:$($Duration)s"
    }
    return $Arguments + "-runtime:$($Duration)s"
}

function Get-Result([string]$Output, [string]$Preset) {
    if ($Preset -in @("upload", "download")) {
        if ($Output -notmatch "Result:\s+\w+\s+(\d+)\s+kbps") {
            throw "Unable to parse throughput result: $Output"
        }
        return [pscustomobject]@{ Metric = [long]$Matches[1]; P50Us = $null; P99999Us = $null }
    }
    if ($Preset -eq "hps") {
        if ($Output -notmatch "Result:\s+(\d+)\s+HPS") {
            throw "Unable to parse HPS result: $Output"
        }
        return [pscustomobject]@{ Metric = [long]$Matches[1]; P50Us = $null; P99999Us = $null }
    }
    if ($Output -notmatch "Result:\s+(\d+)\s+RPS.*50th:\s+(\d+).*99\.999th:\s+(\d+)") {
        throw "Unable to parse RPS result: $Output"
    }
    [pscustomobject]@{
        Metric = [long]$Matches[1]
        P50Us = [long]$Matches[2]
        P99999Us = [long]$Matches[3]
    }
}

function Invoke-Workload(
    [object]$RunDirectory,
    [object]$Scenario,
    [object]$Network,
    [int]$Duration,
    [string]$OutputDirectory
) {
    New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
    Get-ChildItem $RunDirectory.Client, $RunDirectory.Server -Filter "KNSoft.Quic*.pgc" -ErrorAction SilentlyContinue |
        Remove-Item -Force

    $ServerOutput = Join-Path $OutputDirectory "server.stdout.txt"
    $ServerError = Join-Path $OutputDirectory "server.stderr.txt"
    $ClientOutput = Join-Path $OutputDirectory "client.stdout.txt"
    $ClientError = Join-Path $OutputDirectory "client.stderr.txt"
    $ServerArguments = @("-scenario:$($Scenario.preset)", "-io:iocp")
    if ($null -ne $Network) {
        $ServerArguments += "-bind:$($Network.serverAddress)"
        $ServerArguments += "-cc:$($Network.congestionControl)"
    }

    $Server = Start-Process (Join-Path $RunDirectory.Server "secnetperf.exe") -ArgumentList $ServerArguments -WorkingDirectory $RunDirectory.Server -RedirectStandardOutput $ServerOutput -RedirectStandardError $ServerError -PassThru -WindowStyle Hidden
    $Client = $null
    try {
        Wait-ServerReady $Server $ServerOutput
        $Client = Start-Process (Join-Path $RunDirectory.Client "secnetperf.exe") -ArgumentList (Get-ScenarioArguments $Scenario $Network $Duration) -WorkingDirectory $RunDirectory.Client -RedirectStandardOutput $ClientOutput -RedirectStandardError $ClientError -PassThru -WindowStyle Hidden
        $Timeout = [Math]::Max(90000, ($Duration + 90) * 1000)
        if (!$Client.WaitForExit($Timeout)) {
            $Client.Kill()
            $Client.WaitForExit()
            throw "SecNetPerf $($Scenario.name) client timed out."
        }
        if ($Client.ExitCode -ne 0) {
            throw "SecNetPerf $($Scenario.name) client failed with exit code $($Client.ExitCode)."
        }
    } finally {
        if (!$Server.HasExited) {
            Stop-Server $Server
        }
    }

    $Output = Get-Content $ClientOutput -Raw
    $Parsed = Get-Result $Output $Scenario.preset
    [pscustomobject]@{
        Metric = $Parsed.Metric
        P50Us = $Parsed.P50Us
        P99999Us = $Parsed.P99999Us
        ClientCpuMs = [Math]::Round($Client.TotalProcessorTime.TotalMilliseconds, 1)
        ServerCpuMs = [Math]::Round($Server.TotalProcessorTime.TotalMilliseconds, 1)
        CpuMs = [Math]::Round($Client.TotalProcessorTime.TotalMilliseconds + $Server.TotalProcessorTime.TotalMilliseconds, 1)
        ClientPgc = @(Get-ChildItem $RunDirectory.Client -Filter "KNSoft.Quic*.pgc")
        ServerPgc = @(Get-ChildItem $RunDirectory.Server -Filter "KNSoft.Quic*.pgc")
    }
}

function Invoke-TrainingWorkload(
    [object]$RunDirectory,
    [object]$Scenario,
    [object]$Network,
    [int]$Duration,
    [string]$OutputDirectory
) {
    $Result = Invoke-Workload $RunDirectory $Scenario $Network $Duration $OutputDirectory
    if ($Result.ClientPgc.Count -ne 1 -or $Result.ServerPgc.Count -ne 1) {
        throw "Expected one client and one server PGC for $($Scenario.name); found $($Result.ClientPgc.Count) and $($Result.ServerPgc.Count)."
    }

    $ClientPgc = Join-Path $OutputDirectory "client.pgc"
    $ServerPgc = Join-Path $OutputDirectory "server.pgc"
    Move-Item $Result.ClientPgc[0].FullName $ClientPgc -Force
    Move-Item $Result.ServerPgc[0].FullName $ServerPgc -Force
    return @($ClientPgc, $ServerPgc)
}

function Get-DuoNicAdapters {
    return @(Get-NetAdapter -Name "duo?" -ErrorAction SilentlyContinue)
}

function Resolve-EmulatedNetworkMode([object]$Configuration) {
    $Mode = [string]$Configuration.emulatedNetwork.mode
    if ($Mode -notin @("Auto", "Disabled", "Required")) {
        throw "Unsupported emulated network mode in ${ConfigurationFile}: $Mode"
    }
    $Adapters = Get-DuoNicAdapters
    $AdapterCount = @($Adapters).Count
    if ($Mode -eq "Required" -and $AdapterCount -lt 2) {
        throw "Emulated network training requires a DuoNic adapter pair."
    }
    [pscustomobject]@{
        Mode = $Mode
        Enabled = $Mode -ne "Disabled" -and $AdapterCount -ge 2
        Adapters = $Adapters
    }
}

function Initialize-DuoNic {
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName RdqEnabled -RegistryValue 1 -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName TxQueueSizeExp -RegistryValue 13 -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName RxQueueSizeExp -RegistryValue 13 -NoRestart
    Set-NetAdapterLso "duo?" -IPv4Enabled $false -IPv6Enabled $false -NoRestart
}

function Set-DuoNicProfile([object]$Profile, [string]$RandomSeed) {
    $BufferPackets = [Math]::Max(1, [int](($Profile.rttMs * $Profile.rateMbps) / (1.5 * 8.0) * $Profile.queueRatio * 1.1))
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName DelayMs -RegistryValue ([int]($Profile.rttMs / 2)) -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName RateLimitMbps -RegistryValue $Profile.rateMbps -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName QueueLimitPackets -RegistryValue $BufferPackets -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName RandomLossDenominator -RegistryValue $Profile.lossDenominator -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName RandomReorderDenominator -RegistryValue $Profile.reorderDenominator -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName ReorderDelayDeltaMs -RegistryValue $Profile.reorderDelayMs -NoRestart
    Set-NetAdapterAdvancedProperty "duo?" -DisplayName RandomSeed -RegistryValue $RandomSeed -NoRestart
    $Restarted = $false
    for ($Attempt = 0; $Attempt -lt 3 -and !$Restarted; $Attempt++) {
        try {
            Restart-NetAdapter "duo?"
            $Restarted = $true
        } catch {
            if ($Attempt -eq 2) { throw }
            Start-Sleep -Seconds 1
        }
    }
    Start-Sleep -Seconds 5
    return $BufferPackets
}

function Test-EmulatedNetwork(
    [object]$Configuration,
    [object]$NetworkState,
    [object]$RunDirectory,
    [string]$Name,
    [string]$RandomSeed
) {
    $Profile = $Configuration.emulatedNetwork.profiles | Select-Object -First 1
    $Scenario = Get-Scenario $Configuration "upload"
    try {
        $null = Set-DuoNicProfile $Profile $RandomSeed
        $Network = New-NetworkConfiguration $Configuration $Profile
        $null = Invoke-Workload $RunDirectory $Scenario $Network 1 (Join-Path $TempRoot "Preflight\$Name")
        Write-Host "DuoNic data-plane preflight passed for $Name."
        return $true
    } catch {
        if ($NetworkState.Mode -eq "Required") {
            throw
        }
        Write-Warning "DuoNic data-plane preflight failed for $Name; emulated network training is skipped. $($_.Exception.Message)"
        return $false
    }
}

function Merge-PgcFiles(
    [string]$Manager,
    [string[]]$Files,
    [string]$Pgd,
    [int]$Weight
) {
    for ($Offset = 0; $Offset -lt $Files.Count; $Offset += 100) {
        $Last = [Math]::Min($Offset + 99, $Files.Count - 1)
        $Batch = @($Files[$Offset..$Last])
        $MergeOption = if ($Weight -eq 1) { "/merge" } else { "/merge:$Weight" }
        & $Manager $MergeOption @Batch $Pgd
        if ($LASTEXITCODE -ne 0) {
            throw "PGC merge failed."
        }
    }
}

function Test-ProfileBuild(
    [object]$VisualStudio,
    [string]$Arch,
    [string]$Crt,
    [string]$Pgd,
    [object]$Validation
) {
    $BuildOutput = Invoke-MSBuild $VisualStudio $Arch $Crt "Custom" $Pgd
    $Text = $BuildOutput -join "`n"
    $FunctionMatch = [regex]::Match($Text, "(\d+) of (\d+) functions \(([\d.]+)%\) were optimized using profile data")
    $InstructionMatch = [regex]::Match($Text, "(\d+) of (\d+) instructions \(([\d.]+)%\) were optimized using profile data")
    if (!$FunctionMatch.Success -or !$InstructionMatch.Success) {
        throw "Unable to verify profile coverage for $Arch/$Crt."
    }

    $FunctionPercent = [double]$FunctionMatch.Groups[3].Value
    $InstructionPercent = [double]$InstructionMatch.Groups[3].Value
    if ($FunctionPercent -lt [double]$Validation.minimumProfiledFunctionsPercent -or
        $InstructionPercent -lt [double]$Validation.minimumProfiledInstructionsPercent) {
        throw "Insufficient profile coverage for $Arch/$Crt`: functions $FunctionPercent%, instructions $InstructionPercent%."
    }

    $UnexpectedWarnings = [regex]::Matches($Text, "warning (PG\d+)") |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -ne "PG0188" } |
        Select-Object -Unique
    if ($UnexpectedWarnings) {
        throw "Unexpected PGO warning(s): $($UnexpectedWarnings -join ', ')."
    }

    $OutputArch = Get-OutputArchitecture $Arch
    $Configuration = Get-Configuration $Crt
    $Dll = Join-Path $RepoRoot "OutDir\$OutputArch\$Configuration\KNSoft.Quic.dll"

    [ordered]@{
        profiledFunctions = [int]$FunctionMatch.Groups[1].Value
        totalFunctions = [int]$FunctionMatch.Groups[2].Value
        profiledFunctionsPercent = $FunctionPercent
        profiledInstructionsPercent = $InstructionPercent
        dllSize = (Get-Item $Dll).Length
        dllSha256 = (Get-FileHash $Dll -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-Median([double[]]$Values) {
    $Sorted = @($Values | Sort-Object)
    $Middle = [int][Math]::Floor($Sorted.Count / 2)
    if (($Sorted.Count % 2) -eq 1) {
        return $Sorted[$Middle]
    }
    return ($Sorted[$Middle - 1] + $Sorted[$Middle]) / 2
}

function Copy-CurrentDll([string]$Arch, [string]$Crt, [string]$Destination) {
    $Source = Join-Path $RepoRoot "OutDir\$(Get-OutputArchitecture $Arch)\$(Get-Configuration $Crt)\KNSoft.Quic.dll"
    New-Item -ItemType Directory -Force (Split-Path $Destination -Parent) | Out-Null
    Copy-Item $Source $Destination -Force
}

function Test-Performance(
    [object]$VisualStudio,
    [object]$Configuration,
    [object]$NetworkState,
    [string]$Arch,
    [string]$Crt,
    [object]$Tool,
    [string]$CustomDll
) {
    $BinaryRoot = Join-Path $TempRoot "Binaries\$Arch\$Crt"
    $Variants = [ordered]@{ "KNSoft-Custom" = $CustomDll }

    $null = Invoke-MSBuild $VisualStudio $Arch $Crt "None"
    $NoneDll = Join-Path $BinaryRoot "KNSoft-None\msquic.dll"
    Copy-CurrentDll $Arch $Crt $NoneDll
    $Variants["KNSoft-None"] = $NoneDll

    if ($Arch -in @("x86", "x64")) {
        $null = Invoke-MSBuild $VisualStudio $Arch $Crt "Upstream"
        $UpstreamProfileDll = Join-Path $BinaryRoot "KNSoft-Upstream\msquic.dll"
        Copy-CurrentDll $Arch $Crt $UpstreamProfileDll
        $Variants["KNSoft-Upstream"] = $UpstreamProfileDll
    }
    $Variants["Upstream-MsQuic"] = $Tool.UpstreamDll

    $RunDirectories = @{}
    foreach ($Variant in $Variants.GetEnumerator()) {
        $RunDirectories[$Variant.Key] = Initialize-RunDirectory (Join-Path $TempRoot "TestRuntime\$Arch\$Crt\$($Variant.Key)") $Tool.Executable $Variant.Value $Variant.Value
    }

    $Results = @()
    $Validation = $Configuration.validation
    $TestCases = @($Validation.scenarios | ForEach-Object {
        $Scenario = Get-Scenario $Configuration $_
        [pscustomobject]@{
            Name = $Scenario.name
            Scenario = $Scenario
            Network = $null
            NetworkProfile = $null
        }
    })
    if ($NetworkState.Enabled) {
        $TestCases += @(Get-OptionalProperty $Validation "emulatedNetwork" @() | ForEach-Object {
            $Profile = Get-NetworkProfile $Configuration $_.profile
            $Scenario = Get-Scenario $Configuration $_.scenario
            [pscustomobject]@{
                Name = "network-$($Profile.name)-$($Scenario.name)"
                Scenario = $Scenario
                Network = New-NetworkConfiguration $Configuration $Profile
                NetworkProfile = $Profile
            }
        })
    }

    $NetworkCaseIndex = 0
    foreach ($TestCase in $TestCases) {
        $Scenario = $TestCase.Scenario
        if ($null -ne $TestCase.NetworkProfile) {
            $Seed = $BaseRandomSeed + (128 + $NetworkCaseIndex++).ToString("x2")
            $null = Set-DuoNicProfile $TestCase.NetworkProfile $Seed
            $CaseVariants = @($Variants.GetEnumerator() |
                Where-Object Key -in @("KNSoft-Custom", "KNSoft-None", "Upstream-MsQuic"))
        } else {
            $CaseVariants = @($Variants.GetEnumerator())
        }

        foreach ($Variant in $CaseVariants) {
            Write-Host "Warmup $Arch/$Crt/$($TestCase.Name)/$($Variant.Key)"
            $WarmupDirectory = Join-Path $TempRoot "Results\$Arch\$Crt\runs\$($TestCase.Name)\$($Variant.Key)\warmup"
            $null = Invoke-Workload $RunDirectories[$Variant.Key] $Scenario $TestCase.Network ([int]$Validation.durationSeconds) $WarmupDirectory
        }

        for ($Iteration = 1; $Iteration -le [int]$Validation.iterations; $Iteration++) {
            $Order = @($CaseVariants)
            if (($Iteration % 2) -eq 0) {
                [array]::Reverse($Order)
            }
            foreach ($Variant in $Order) {
                Write-Host "Benchmark $Arch/$Crt/$($TestCase.Name)/$($Variant.Key) ($Iteration/$($Validation.iterations))"
                $OutputDirectory = Join-Path $TempRoot "Results\$Arch\$Crt\runs\$($TestCase.Name)\$($Variant.Key)\run-$Iteration"
                $Result = Invoke-Workload $RunDirectories[$Variant.Key] $Scenario $TestCase.Network ([int]$Validation.durationSeconds) $OutputDirectory
                $Results += [pscustomobject]@{
                    Architecture = $Arch
                    Runtime = $Crt
                    Variant = $Variant.Key
                    Scenario = $TestCase.Name
                    Preset = $Scenario.preset
                    Iteration = $Iteration
                    Metric = $Result.Metric
                    P50Us = $Result.P50Us
                    P99999Us = $Result.P99999Us
                    CpuMs = $Result.CpuMs
                    DllBytes = (Get-Item $Variant.Value).Length
                }
            }
        }
    }

    $ResultRoot = Join-Path $TempRoot "Results\$Arch\$Crt"
    New-Item -ItemType Directory -Force $ResultRoot | Out-Null
    $Results | Export-Csv (Join-Path $ResultRoot "raw-results.csv") -NoTypeInformation -Encoding utf8
    $Results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ResultRoot "raw-results.json") -Encoding utf8

    $Summary = foreach ($Group in ($Results | Group-Object Variant, Scenario)) {
        $Rows = @($Group.Group)
        [pscustomobject]@{
            Architecture = $Arch
            Runtime = $Crt
            Variant = $Rows[0].Variant
            Scenario = $Rows[0].Scenario
            Metric = [Math]::Round((Get-Median $Rows.Metric), 3)
            P50Us = if ($null -eq $Rows[0].P50Us) { $null } else { [Math]::Round((Get-Median $Rows.P50Us), 3) }
            P99999Us = if ($null -eq $Rows[0].P99999Us) { $null } else { [Math]::Round((Get-Median $Rows.P99999Us), 3) }
            CpuMs = [Math]::Round((Get-Median $Rows.CpuMs), 3)
            DllBytes = $Rows[0].DllBytes
        }
    }
    $Summary | Sort-Object Scenario, Variant | Export-Csv (Join-Path $ResultRoot "summary.csv") -NoTypeInformation -Encoding utf8

    # Keep latency percentiles as diagnostics; like upstream, gate only the primary metric.
    $Comparisons = @()
    foreach ($TestCase in $TestCases) {
        $Baseline = Get-Median @($Results |
            Where-Object { $_.Scenario -eq $TestCase.Name -and $_.Variant -eq "KNSoft-None" } |
            ForEach-Object { [double]$_.Metric })
        $Candidate = Get-Median @($Results |
            Where-Object { $_.Scenario -eq $TestCase.Name -and $_.Variant -eq "KNSoft-Custom" } |
            ForEach-Object { [double]$_.Metric })
        $Delta = [Math]::Round((($Candidate / $Baseline) - 1) * 100, 3)
        $Comparisons += [pscustomobject]@{
            Group = if ($null -eq $TestCase.NetworkProfile) { "Local" } else { "EmulatedNetwork" }
            Scenario = $TestCase.Name
            Baseline = $Baseline
            Candidate = $Candidate
            DeltaPercent = $Delta
            LogRatio = [Math]::Log($Candidate / $Baseline)
        }
    }

    # Hosted runners are noisy enough for individual scenarios to be bimodal.
    # Gate the geometric mean so every scenario contributes an equal ratio.
    $AggregateComparisons = @($Comparisons | Group-Object Group | ForEach-Object {
        $Rows = @($_.Group)
        $Worst = $Rows | Sort-Object DeltaPercent | Select-Object -First 1
        [ordered]@{
            group = $_.Name
            scenarioCount = $Rows.Count
            deltaPercent = [Math]::Round(([Math]::Exp(($Rows.LogRatio | Measure-Object -Average).Average) - 1) * 100, 3)
            worstScenario = $Worst.Scenario
            worstScenarioDeltaPercent = $Worst.DeltaPercent
        }
    })
    $Regressions = @($AggregateComparisons |
        Where-Object { $_.deltaPercent -lt -[double]$Validation.allowedRegressionPercent } |
        ForEach-Object { "$($_.group) aggregate $($_.deltaPercent)%" })
    if ($Regressions) {
        throw "Aggregate performance regression against unprofiled KNSoft.Quic exceeds $($Validation.allowedRegressionPercent)%: $($Regressions -join ', ')."
    }

    [ordered]@{
        iterations = [int]$Validation.iterations
        durationSeconds = [int]$Validation.durationSeconds
        scenarios = @($TestCases.Name)
        regressionBaseline = "KNSoft-None"
        allowedRegressionPercent = [double]$Validation.allowedRegressionPercent
        aggregateComparisons = $AggregateComparisons
        passed = $true
    }
}

if (!(Test-Path $ConfigurationFile)) {
    throw "Training configuration was not found: $ConfigurationFile"
}
$Training = Get-Content $ConfigurationFile -Raw | ConvertFrom-Json
$EffectiveIterations = [int]$Training.iterations
$VisualStudio = Get-VisualStudio
$NetworkState = Resolve-EmulatedNetworkMode $Training
if ($NetworkState.Enabled) {
    Initialize-DuoNic
} elseif ($NetworkState.Mode -eq "Auto") {
    Write-Host "DuoNic was not found; emulated network training is skipped."
}

$RepoCommit = (git -C $RepoRoot rev-parse HEAD).Trim()
$MsQuicCommit = (git -C $MsQuicRoot rev-parse HEAD).Trim()
$RepoDirty = [bool](git -C $RepoRoot status --porcelain)
$MsQuicDirty = [bool](git -C $MsQuicRoot status --porcelain)
$GeneratedAt = [DateTime]::UtcNow.ToString("o")
$BaseRandomSeed = "41473a2e60b6958500ec0add7dcfb9"

foreach ($Arch in $Architecture) {
    Assert-HostSupport $Arch
    $PgoTools = Get-PgoTools $VisualStudio $Arch
    $Tools = @{}
    foreach ($Crt in $Runtime) {
        $Tools[$Crt] = Get-SecNetPerf $Arch $Crt
    }
    $ArchOutput = Get-OutputArchitecture $Arch
    $ManifestPath = Join-Path $ProfileRoot "$ArchOutput\manifest.json"
    $StagedProfileRoot = Join-Path $TempRoot "Profiles\$ArchOutput"
    if (Test-Path $StagedProfileRoot) {
        Remove-Item -LiteralPath $StagedProfileRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force $StagedProfileRoot | Out-Null
    $Profiles = @()
    if (Test-Path $ManifestPath) {
        $ExistingManifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        $Profiles = @($ExistingManifest.profiles | Where-Object { $_.runtime -notin $Runtime })
    }

    foreach ($Crt in $Runtime) {
        $Configuration = Get-Configuration $Crt
        $Dll = Join-Path $RepoRoot "OutDir\$ArchOutput\$Configuration\KNSoft.Quic.dll"
        $InitialPgd = Join-Path $RepoRoot "KNSoft.Quic\IntDir\$ArchOutput\$Configuration\KNSoft.Quic.pgd"
        $RuntimeProfileRoot = Join-Path $StagedProfileRoot $Crt
        $PgcRoot = Join-Path $TempRoot "PGC\$ArchOutput\$Crt"
        $FinalPgd = Join-Path $RuntimeProfileRoot "KNSoft.Quic.pgd"

        Write-Host "Building instrumented KNSoft.Quic for $Arch/$Crt"
        $null = Invoke-MSBuild $VisualStudio $Arch $Crt "Instrument"
        if (!(Test-Path $Dll) -or !(Test-Path $InitialPgd)) {
            throw "Instrumented DLL or initial PGD is missing for $Arch/$Crt."
        }

        if (Test-Path $PgcRoot) {
            Remove-Item -LiteralPath $PgcRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force $RuntimeProfileRoot, $PgcRoot | Out-Null
        Copy-Item $InitialPgd $FinalPgd

        $RunDirectory = Initialize-RunDirectory (Join-Path $TempRoot "Runtime\$ArchOutput\$Crt") $Tools[$Crt].Executable $Dll $Dll $PgoTools.Runtime
        if ($NetworkState.Enabled) {
            $NetworkState.Enabled = Test-EmulatedNetwork $Training $NetworkState $RunDirectory "$Arch-$Crt" ($BaseRandomSeed + "00")
        }
        $LocalPgc = @()
        $LocalPgcGroups = @{}
        for ($Iteration = 1; $Iteration -le $EffectiveIterations; $Iteration++) {
            foreach ($Scenario in $Training.scenarios) {
                $Duration = Get-ScenarioDuration $Scenario
                Write-Host "Training local $Arch/$Crt/$($Scenario.name) ($Iteration/$EffectiveIterations)"
                $OutputDirectory = Join-Path $PgcRoot "local\$Iteration-$($Scenario.name)"
                $Files = @(Invoke-TrainingWorkload $RunDirectory $Scenario $null $Duration $OutputDirectory)
                $Weight = Get-ScenarioWeight $Scenario
                $LocalPgc += $Files
                if (!$LocalPgcGroups.ContainsKey($Weight)) {
                    $LocalPgcGroups[$Weight] = @()
                }
                $LocalPgcGroups[$Weight] += $Files
            }
        }

        $EmulatedPgc = @()
        $EmulatedPgcGroups = @{}
        $EmulatedRuns = @()
        if ($NetworkState.Enabled) {
            $NetworkIndex = 0
            foreach ($NetworkProfile in $Training.emulatedNetwork.profiles) {
                for ($Iteration = 1; $Iteration -le [int]$Training.emulatedNetwork.iterations; $Iteration++) {
                    $Seed = $BaseRandomSeed + ($NetworkIndex++).ToString("x2")
                    $BufferPackets = Set-DuoNicProfile $NetworkProfile $Seed
                    $Network = New-NetworkConfiguration $Training $NetworkProfile
                    $ScenarioSpecifications = @(Get-OptionalProperty $NetworkProfile "scenarios" $Training.emulatedNetwork.scenarios)
                    foreach ($ScenarioSpecification in $ScenarioSpecifications) {
                        $Scenario = Resolve-Scenario $Training $ScenarioSpecification
                        $Duration = Get-ScenarioDuration $Scenario
                        Write-Host "Training emulated $Arch/$Crt/$($NetworkProfile.name)/$($Scenario.name) ($Iteration/$($Training.emulatedNetwork.iterations))"
                        $OutputDirectory = Join-Path $PgcRoot "emulated\$($NetworkProfile.name)\$Iteration-$($Scenario.name)"
                        $Files = @(Invoke-TrainingWorkload $RunDirectory $Scenario $Network $Duration $OutputDirectory)
                        $Weight = Get-ScenarioWeight $Scenario
                        $EmulatedPgc += $Files
                        if (!$EmulatedPgcGroups.ContainsKey($Weight)) {
                            $EmulatedPgcGroups[$Weight] = @()
                        }
                        $EmulatedPgcGroups[$Weight] += $Files
                    }
                    $EmulatedRuns += [ordered]@{
                        profile = $NetworkProfile.name
                        iteration = $Iteration
                        clientAddress = $Network.clientAddress
                        serverAddress = $Network.serverAddress
                        scenarios = $ScenarioSpecifications
                        randomSeed = $Seed
                        bufferPackets = $BufferPackets
                    }
                }
            }
        }

        $LocalWeight = if ($NetworkState.Enabled) { [int]$Training.localWeight } else { 1 }
        foreach ($Weight in @($LocalPgcGroups.Keys | Sort-Object)) {
            Merge-PgcFiles $PgoTools.Manager $LocalPgcGroups[$Weight] $FinalPgd ($LocalWeight * [int]$Weight)
        }
        foreach ($Weight in @($EmulatedPgcGroups.Keys | Sort-Object)) {
            Merge-PgcFiles $PgoTools.Manager $EmulatedPgcGroups[$Weight] $FinalPgd ([int]$Training.emulatedWeight * [int]$Weight)
        }

        $SummaryCopy = Join-Path $PgcRoot "summary.pgd"
        Copy-Item $FinalPgd $SummaryCopy
        & $PgoTools.Manager /summary $SummaryCopy 2>&1 |
            Set-Content (Join-Path $PgcRoot "summary.txt") -Encoding utf8
        Remove-Item $SummaryCopy -Force

        Write-Host "Validating profile build for $Arch/$Crt"
        $BuildValidation = Test-ProfileBuild $VisualStudio $Arch $Crt $FinalPgd $Training.validation
        $CustomDll = Join-Path $TempRoot "Binaries\$Arch\$Crt\KNSoft-Custom\msquic.dll"
        Copy-CurrentDll $Arch $Crt $CustomDll
        $PerformanceValidation = Test-Performance $VisualStudio $Training $NetworkState $Arch $Crt $Tools[$Crt] $CustomDll

        $ProfileFile = Get-Item $FinalPgd
        $Profiles += [ordered]@{
            runtime = $Crt
            configuration = $Configuration
            pgd = "$Crt/KNSoft.Quic.pgd"
            pgdSize = $ProfileFile.Length
            pgdSha256 = (Get-FileHash $FinalPgd -Algorithm SHA256).Hash.ToLowerInvariant()
            pgcCount = $LocalPgc.Count + $EmulatedPgc.Count
            generatedAtUtc = $GeneratedAt
            repositoryCommit = $RepoCommit
            repositoryDirty = $RepoDirty
            msquicCommit = $MsQuicCommit
            msquicDirty = $MsQuicDirty
            visualStudioVersion = $VisualStudio.InstallationVersion
            vcToolsVersion = $VisualStudio.VCToolsVersion
            training = [ordered]@{
                localIterations = $EffectiveIterations
                localWeight = $LocalWeight
                scenarios = @($Training.scenarios)
                emulatedNetwork = [ordered]@{
                    requestedMode = $NetworkState.Mode
                    enabled = $NetworkState.Enabled
                    weight = if ($NetworkState.Enabled) { [int]$Training.emulatedWeight } else { 0 }
                    runs = $EmulatedRuns
                }
            }
            buildValidation = $BuildValidation
            performanceValidation = $PerformanceValidation
        }
    }

    $Manifest = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = $GeneratedAt
        architecture = $Arch
        tls = "Schannel"
        datapath = "Winsock/IOCP"
        host = [ordered]@{
            os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            processorCount = [Environment]::ProcessorCount
        }
        profiles = @($Profiles | Sort-Object runtime)
    }
    $StagedManifestPath = Join-Path $StagedProfileRoot "manifest.json"
    $Manifest | ConvertTo-Json -Depth 12 | Set-Content $StagedManifestPath -Encoding utf8

    #
    # Keep the previously validated profiles intact until every selected CRT
    # has completed training and validation.
    #
    $PendingProfiles = foreach ($Crt in $Runtime) {
        $Destination = Join-Path $ProfileRoot "$ArchOutput\$Crt\KNSoft.Quic.pgd"
        New-Item -ItemType Directory -Force (Split-Path $Destination -Parent) | Out-Null
        $Pending = "$Destination.new"
        Copy-Item (Join-Path $StagedProfileRoot "$Crt\KNSoft.Quic.pgd") $Pending -Force
        [pscustomobject]@{ Pending = $Pending; Destination = $Destination }
    }
    New-Item -ItemType Directory -Force (Split-Path $ManifestPath -Parent) | Out-Null
    $PendingManifest = "$ManifestPath.new"
    Copy-Item $StagedManifestPath $PendingManifest -Force
    foreach ($Profile in $PendingProfiles) {
        Move-Item $Profile.Pending $Profile.Destination -Force
    }
    Move-Item $PendingManifest $ManifestPath -Force
}

Write-Host "PGO training and validation completed. Profiles are under $ProfileRoot."
