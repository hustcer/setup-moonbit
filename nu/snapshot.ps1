#!/usr/bin/env pwsh
#Requires -Version 7

<#
.SYNOPSIS
    Moonbit snap script.
.DESCRIPTION
    Snap moonbit core and binaries.
.PARAMETER Channel
    Channel to snap. Default is latest.
.PARAMETER Merge
    Merge component index files and produce the main index.
.PARAMETER Production
    Production mode. Default is development mode.
.PARAMETER SnapToolchain
    Snap moonbit toolchain. Default is to snap moonbit core.
.PARAMETER KeepArtifacts
    Keep artifacts between runs.
.LINK
    https://github.com/chawyehsu/moonbit-binaries
#>
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateSet('latest', 'nightly')]
    [string]$Channel = 'latest',
    [Parameter(Mandatory = $false)]
    [switch]$Merge,
    [Parameter(Mandatory = $false)]
    [switch]$Production = $(if ($env:CI) { $true } else { $false }),
    [Parameter(Mandatory = $false)]
    [switch]$SnapToolchain,
    [Parameter(Mandatory = $false)]
    [switch]$KeepArtifacts = $Merge
)

Set-StrictMode -Version Latest

$DebugPreference = if ((-not $Production) -or $env:CI) { 'Continue' } else { 'SilentlyContinue' }
$ErrorActionPreference = 'Stop'
$Script:DateNightly = '0000-00-00'

$DOWNLOAD_DIR = "$PSScriptRoot/tmp/download"
$GHA_ARTIFACTS_DIR = "$PSScriptRoot/tmp/gha-artifacts"
$DIST_DIR = "$PSScriptRoot/tmp/dist"
$DIST_V2_BASEDIR = "$DIST_DIR/v2"

$INDEX_FILE = "$DIST_V2_BASEDIR/index.json"
$CHANNEL_INDEX_FILE = "$DIST_V2_BASEDIR/channel-$Channel.json"

# Remote URLs
$LIBCORE_URL = "https://cli.moonbitlang.com/cores/core-$Channel.zip"

function Clear-WorkingDir {
    if ($Production -and (-not $KeepArtifacts)) {
        Write-Debug 'Clearing working directories ...'
        Remove-Item $DOWNLOAD_DIR -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item $GHA_ARTIFACTS_DIR -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Get-DeployedIndex {
    Write-Debug 'Getting the latest deployed index ...'

    if ($env:CI) {
        # CI clone the deployed index using the checkout action
        return
    }

    New-Item -Path $DIST_DIR -ItemType Directory -Force | Out-Null
    Push-Location $DIST_DIR
    Remove-Item '.git' -Recurse -Force -ErrorAction SilentlyContinue
    & git init --quiet
    & git remote add origin 'https://github.com/chawyehsu/moonbit-binaries'
    & git fetch --quiet
    & git reset --hard origin/gh-pages --quiet
    & git clean -fd --quiet
    Pop-Location
}

function Get-LibcoreModifiedDate {
    Write-Debug 'Checking last modified date of moonbit libcore ...'
    $libcoreRemoteLastModified = Get-Date "$((Invoke-WebRequest -Method HEAD $LIBCORE_URL).Headers.'Last-Modified')"
    Write-Debug "Moonbit libcore remote last modified: $($libcoreRemoteLastModified.ToUniversalTime())"
    if ($Channel -eq 'nightly') {
        $Script:DateNightly = $libcoreRemoteLastModified.ToUniversalTime().ToString('yyyy-MM-dd')
    }
    return $libcoreRemoteLastModified
}

function Invoke-SnapLibcore {
    $libcoreRemoteLastModified = Get-LibcoreModifiedDate

    $channelIndexLastModified = $null
    if (Test-Path $CHANNEL_INDEX_FILE) {
        $channelIndex = Get-Content -Path $CHANNEL_INDEX_FILE | ConvertFrom-Json -AsHashtable
        $channelIndexLastModified = [DateTime]::ParseExact($channelIndex.lastModified, "yyyyMMdd'T'HHmmssffff'Z'", $null)
        Write-Debug "Channel index last modified: $channelIndexLastModified"
    }

    if ($channelIndexLastModified -and ($libcoreRemoteLastModified -lt $channelIndexLastModified)) {
        Write-Host "INFO: libcore is up to date. (channel: $Channel)"
        return
    }

    Write-Debug 'Downloading moonbit libcore pkg ...'
    New-Item -Path $DOWNLOAD_DIR -ItemType Directory -Force | Out-Null
    Push-Location $DOWNLOAD_DIR

    $filename = "moonbit-core-$Channel.zip"
    if (-not ($KeepArtifacts -and (Test-Path $filename))) {
        Invoke-WebRequest -Uri $LIBCORE_URL -OutFile $filename
    }

    Write-Debug 'Getting moonbit libcore version number ...'
    Remove-Item -Path "$DOWNLOAD_DIR/core-$Channel" -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $filename -DestinationPath "$DOWNLOAD_DIR/core-$Channel" -Force
    $libcoreActualVersion = (Get-Content -Path "$DOWNLOAD_DIR/core-$Channel/core/moon.mod.json" | ConvertFrom-Json).version
    $libcorePkgSha256 = (Get-FileHash -Path $filename -Algorithm SHA256).Hash.ToLower()

    Write-Host "INFO: Found moonbit libcore version: $libcoreActualVersion"
    $componentLibcore = [ordered]@{
        version = $libcoreActualVersion
        date    = $Script:DateNightly
        name    = 'libcore'
        file    = switch ($Channel) {
            'latest' { "moonbit-core-v$libcoreActualVersion-universal.zip" }
            'nightly' { "moonbit-core-nightly-$($Script:DateNightly)-universal.zip" }
        }
        sha256  = $libcorePkgSha256
    }

    Write-Debug 'Saving libcore component json file ...'
    New-Item -Path $GHA_ARTIFACTS_DIR -ItemType Directory -Force | Out-Null
    $componentLibcore | ConvertTo-Json -Depth 99 | Set-Content -Path "$GHA_ARTIFACTS_DIR/component-moonbit-core.json"

    Write-Debug 'Saving moonbit libcore pkg ...'
    Copy-Item -Path $filename -Destination "$GHA_ARTIFACTS_DIR/$($componentLibcore.file)" -Force
    "$libcorePkgSha256  *$($componentLibcore.file)" | Out-File -FilePath "$GHA_ARTIFACTS_DIR/$($componentLibcore.file).sha256" -Encoding ascii -Force
    Pop-Location
}

function Invoke-SnapToolchain {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('aarch64-apple-darwin', 'x86_64-apple-darwin', 'x86_64-unknown-linux', 'x86_64-pc-windows')]
        [string]$Arch
    )

    $TOOLCHAIN_URL = switch ($Arch) {
        'aarch64-apple-darwin' { "https://cli.moonbitlang.com/binaries/$Channel/moonbit-darwin-aarch64.tar.gz" }
        'x86_64-apple-darwin' { "https://cli.moonbitlang.com/binaries/$Channel/moonbit-darwin-x86_64.tar.gz" }
        'x86_64-unknown-linux' { "https://cli.moonbitlang.com/binaries/$Channel/moonbit-linux-x86_64.tar.gz" }
        'x86_64-pc-windows' { "https://cli.moonbitlang.com/binaries/$Channel/moonbit-windows-x86_64.zip" }
    }

    if ($Channel -eq 'nightly') {
        # (NOTES): it is expected that the date of libcore is unchanged between jobs
        Write-Debug 'Getting nightly build date from libcore ...'
        Get-LibcoreModifiedDate | Out-Null
    }

    Write-Debug 'Checking last modified date of moonbit toolchain ...'
    $toolchainRemoteLastModified = Get-Date "$((Invoke-WebRequest -Method HEAD $TOOLCHAIN_URL).Headers.'Last-Modified')"
    Write-Debug "Moonbit toolchain remote last modified: $($toolchainRemoteLastModified.ToUniversalTime())"

    $channelIndexLastModified = $null
    if (Test-Path $CHANNEL_INDEX_FILE) {
        $channelIndex = Get-Content -Path $CHANNEL_INDEX_FILE | ConvertFrom-Json -AsHashtable
        $channelIndexLastModified = [DateTime]::ParseExact($channelIndex.lastModified, "yyyyMMdd'T'HHmmssffff'Z'", $null)
        Write-Debug "Channel index last modified: $channelIndexLastModified"
    }

    if ($channelIndexLastModified -and ($toolchainRemoteLastModified -lt $channelIndexLastModified)) {
        Write-Host "INFO: moonbit toolchain is up to date. (arch: $Arch, channel: $Channel)"
        return
    }

    Write-Debug 'Downloading moonbit toolchain pkg ...'
    New-Item -Path $DOWNLOAD_DIR -ItemType Directory -Force | Out-Null
    Push-Location $DOWNLOAD_DIR

    $filename = switch ($Arch) {
        'aarch64-apple-darwin' { "moonbit-$Channel-darwin-arm64.tar.gz" }
        'x86_64-apple-darwin' { "moonbit-$Channel-darwin-x64.tar.gz" }
        'x86_64-unknown-linux' { "moonbit-$Channel-linux-x64.tar.gz" }
        'x86_64-pc-windows' { "moonbit-$Channel-win-x64.zip" }
    }
    if (-not ($KeepArtifacts -and (Test-Path $filename))) {
        Invoke-WebRequest -Uri $TOOLCHAIN_URL -OutFile $filename
    }

    Write-Debug 'Getting moonbit toolchain version number ...'
    Remove-Item -Path "$DOWNLOAD_DIR/moonbit-$Channel" -Recurse -Force -ErrorAction SilentlyContinue
    if ($Arch -match 'windows') {
        Expand-Archive -Path $filename -DestinationPath "$DOWNLOAD_DIR/moonbit-$Channel" -Force
    } else {
        mkdir -p "$DOWNLOAD_DIR/moonbit-$Channel"
        tar -xf $filename -C "$DOWNLOAD_DIR/moonbit-$Channel"
        chmod +x "$DOWNLOAD_DIR/moonbit-$Channel/bin/moonc"
    }

    Push-Location "$DOWNLOAD_DIR/moonbit-$Channel/bin"
    $VersionString = (& ./moonc -v)
    Pop-Location

    if ($VersionString -match 'v([\d.]+)(?:\+([a-f0-9]+))') {
        $toolchainActualVersion = "$($Matches[1])+$($Matches[2])"
        $toolchainPkgSha256 = (Get-FileHash -Path $filename -Algorithm SHA256).Hash.ToLower()

        Write-Host "INFO: Found moonbit toolchain version: $toolchainActualVersion"
        $toolchainPkgVersionMark = switch ($Channel) {
            'latest' { "v$toolchainActualVersion" }
            'nightly' { "nightly-$($Script:DateNightly)" }
        }

        $componentToolchain = [ordered]@{
            version  = $toolchainActualVersion
            name     = 'toolchain'
            file     = switch ($Arch) {
                'aarch64-apple-darwin' { "moonbit-$toolchainPkgVersionMark-aarch64-apple-darwin.tar.gz" }
                'x86_64-apple-darwin' { "moonbit-$toolchainPkgVersionMark-x86_64-apple-darwin.tar.gz" }
                'x86_64-unknown-linux' { "moonbit-$toolchainPkgVersionMark-x86_64-unknown-linux.tar.gz" }
                'x86_64-pc-windows' { "moonbit-$toolchainPkgVersionMark-x86_64-pc-windows.zip" }
            }
            'sha256' = $toolchainPkgSha256
        }

        Write-Debug 'Saving toolchain component json file ...'
        New-Item -Path $GHA_ARTIFACTS_DIR -ItemType Directory -Force | Out-Null
        $componentToolchain | ConvertTo-Json -Depth 99 | Set-Content -Path "$GHA_ARTIFACTS_DIR/component-moonbit-toolchain-$Arch.json"

        Write-Debug 'Saving moonbit toolchain pkg ...'
        Copy-Item -Path $filename -Destination "$GHA_ARTIFACTS_DIR/$($componentToolchain.file)" -Force
        "$toolchainPkgSha256  *$($componentToolchain.file)" | Out-File -FilePath "$GHA_ARTIFACTS_DIR/$($componentToolchain.file).sha256" -Encoding ascii -Force
        Pop-Location
    } else {
        Write-Error "Unexpected moonbit toolchain version number found: $VersionString"
        exit 1
    }
}

function Invoke-MergeIndex {
    $componentCoreJsonFile = "$GHA_ARTIFACTS_DIR/component-moonbit-core.json"
    if (-not (Test-Path $componentCoreJsonFile)) {
        Write-Error 'Missing component-moonbit-core.json'
        exit 1
    }

    $componentCoreJson = Get-Content -Path $componentCoreJsonFile | ConvertFrom-Json -AsHashtable
    $dateUpdated = (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmssffff'Z'")

    if ($Channel -eq 'nightly') {
        $Script:DateNightly = $componentCoreJson.date
    }

    # Update channel index
    if (-not (Test-Path $CHANNEL_INDEX_FILE)) {
        $initChannelIndex = [ordered]@{
            version      = 2
            lastModified = $dateUpdated
            releases     = @()
        }
        Write-Debug 'Creating channel index file ...'
        $initChannelIndex | ConvertTo-Json -Depth 99 | Set-Content -Path $CHANNEL_INDEX_FILE
    }
    $channelIndex = Get-Content -Path $CHANNEL_INDEX_FILE | ConvertFrom-Json -AsHashtable

    $channelIndexNewRelease = switch ($Channel) {
        'latest' {
            [ordered]@{
                version = $componentCoreJson.version
            }
        }
        'nightly' {
            [ordered]@{
                version = $componentCoreJson.version
                date    = $Script:DateNightly
            }
        }
    }

    # Prevent duplicate releases written to the channel index
    $releaseAlreadyExists = (
        $channelIndex.releases | Where-Object {
            $r = $_
            switch ($Channel) {
                # For latest channel, the (compiler) version is checked.
                'latest' { $r.version -eq $channelIndexNewRelease.version }
                # For nightly channel, only the date is checked, since the
                # (compiler) version may not be unique across different nightly builds.
                'nightly' { $r.date -eq $Script:DateNightly }
            }
        } | Measure-Object
    ).Count -gt 0

    if ($releaseAlreadyExists) {
        $msg = switch ($Channel) {
            'latest' { "latest: $($channelIndexNewRelease.version)" }
            'nightly' { "nightly: $Script:DateNightly" }
        }

        Write-Warning "Duplicate release found in channel index. ($msg)"
        exit 1
    }

    $channelIndex.lastModified = $dateUpdated
    $channelIndex.releases = @($channelIndex.releases; $channelIndexNewRelease)
    Write-Host 'INFO: Saving channel index ...'
    $channelIndex | ConvertTo-Json -Depth 99 | Set-Content -Path $CHANNEL_INDEX_FILE

    # Write component index
    @(
        'aarch64-apple-darwin'
        'x86_64-apple-darwin'
        'x86_64-unknown-linux'
        'x86_64-pc-windows'
    ) | ForEach-Object {
        $componentToolchainJsonFile = "$GHA_ARTIFACTS_DIR/component-moonbit-toolchain-$_.json"
        if (-not (Test-Path $componentToolchainJsonFile)) {
            Write-Error "Missing component-moonbit-toolchain-$_.json"
            exit 1
        }

        $componentToolchainJson = Get-Content -Path $componentToolchainJsonFile | ConvertFrom-Json -AsHashtable

        $componentToolchainVersion = $componentToolchainJson.version
        $componentCoreVersion = $componentCoreJson.version

        if ($componentToolchainVersion -ne $componentCoreVersion) {
            Write-Error "Version mismatch between core ($componentCoreVersion) and toolchain ($componentToolchainVersion, arch: $_)"
            exit 1
        }

        $componentIndex = [ordered]@{
            version    = 2
            components = @(
                $componentToolchainJson | Select-Object -Property name, file, sha256
                $componentCoreJson | Select-Object -Property name, file, sha256
            )
        }

        Write-Host "INFO: Saving component index '$_.json' ..."
        $componentIndexPath = switch ($Channel) {
            'latest' { "$DIST_V2_BASEDIR/latest/$componentToolchainVersion" }
            'nightly' { "$DIST_V2_BASEDIR/nightly/$Script:DateNightly" }
        }

        New-Item -Path $componentIndexPath -ItemType Directory -Force | Out-Null
        $componentIndex | ConvertTo-Json -Depth 99 | Set-Content -Path "$componentIndexPath/$_.json"
    }

    # Update main index
    $index = Get-Content -Path $INDEX_FILE | ConvertFrom-Json -AsHashtable
    $index.lastModified = $dateUpdated
    $shouldInitChannel = $true

    foreach ($c in $index.channels) {
        if ($c.name -eq $Channel) {
            $shouldInitChannel = $false
            $c.version = $channelIndexNewRelease.version
            if ($Channel -eq 'nightly') {
                $c.date = $Script:DateNightly
            }
        }
    }

    if ($shouldInitChannel) {
        $initChannel = [ordered]@{
            name    = $Channel
            version = $channelIndexNewRelease.version
        }
        if ($Channel -eq 'nightly') {
            $initChannel.date = $Script:DateNightly
        }

        $index.channels = @($index.channels; $initChannel)
    }

    Write-Host 'INFO: Saving main index ...'
    $index | ConvertTo-Json -Depth 99 | Set-Content -Path $INDEX_FILE
}

Clear-WorkingDir
Write-Host "INFO: Channel set to: $Channel"

Get-DeployedIndex

if ($Merge) {
    Invoke-MergeIndex
} elseif ($SnapToolchain) {
    if ($IsWindows) {
        Invoke-SnapToolchain -Arch 'x86_64-pc-windows'
    }

    if ($IsLinux) {
        Invoke-SnapToolchain -Arch 'x86_64-unknown-linux'
    }

    if ($IsMacOS) {
        $arch = (uname -sm)
        if ($arch -match 'arm64') {
            Invoke-SnapToolchain -Arch 'aarch64-apple-darwin'
        } else {
            Invoke-SnapToolchain -Arch 'x86_64-apple-darwin'
        }
    }
} else {
    Invoke-SnapLibcore
}
