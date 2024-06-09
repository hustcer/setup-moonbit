#!/usr/bin/env pwsh
if ($env:MOONBIT_INSTALL_VERSION) {
    $Version = $env:MOONBIT_INSTALL_VERSION
} else {
    $Version = "latest"
}

$Version = $Version -replace '\+', '%2B'

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
  Write-Output "Install Failed:"
  Write-Output "MoonBit for Windows is currently only available for x86 64-bit Windows.`n"
  return 1
}

$ErrorActionPreference = "Stop"

$MoonHome = "${HOME}\.moon"
$MoonBin = "${MoonHome}\bin"
$MoonLib = "${MoonHome}\lib"

$CLI_MOONBIT = "https://cli.moonbitlang.com"

$MoonbitUri = "$CLI_MOONBIT/binaries/$Version/moonbit-windows-x86_64.zip"
$CoreUri = "$CLI_MOONBIT/cores/core-$Version.zip"

if (-not (Test-Path -Path $MoonBin -PathType Container)) {
  New-Item -Path $MoonBin -ItemType Directory
}

if (-not (Test-Path -Path $MoonLib -PathType Container)) {
  New-Item -Path $MoonLib -ItemType Directory
}

try {
  Write-Output "Downloading moonbit ..."
  Invoke-WebRequest -Uri $MoonbitUri -OutFile $MoonHome\moonbit.zip
  Expand-Archive $MoonHome\moonbit.zip -DestinationPath $MoonBin -Force
  Remove-Item -Force $MoonHome\moonbit.zip

  Write-Output "Downloading core ..."
  Invoke-WebRequest -Uri $CoreUri -OutFile $MoonHome\core.zip
  if (Test-Path -Path $MoonLib\core) {
    Remove-Item -Force -Recurse $MoonLib\core
  }
  Expand-Archive $MoonHome\core.zip -DestinationPath $MoonLib -Force
  Remove-Item -Force $MoonHome\core.zip

  Write-Output "Bundling core ..."
  Push-Location $MoonLib\core

  $OldPath = $env:Path
  $env:Path = $MoonBin
  moon.exe bundle --all
  $env:PATH = $OldPath

  Pop-Location
}
catch {
  Write-Output "Install Failed:"
  Write-Output $_.Exception.Message
  return 1
}

if ($env:Path -split ';' -notcontains $MoonBin) {
  [System.Environment]::SetEnvironmentVariable("PATH", "$MoonBin;$env:PATH", [System.EnvironmentVariableTarget]::User)

  Write-Output "Added ~/.moon/bin to the PATH."
  Write-Output "Please restart your terminal to use moonbit."
}
else {
  Write-Output "Moonbit installed successfully."
}

Write-Output "To verify the download binaries, you can check https://www.moonbitlang.com/download#verifying-binaries for instructions."