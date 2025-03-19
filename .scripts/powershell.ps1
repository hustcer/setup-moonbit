#!/usr/bin/env pwsh
if ($env:MOONBIT_INSTALL_VERSION) {
  $Version = $env:MOONBIT_INSTALL_VERSION
}
else {
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

if ($env:MOONBIT_INSTALL_DEV) {
  $MoonbitUri = "$CLI_MOONBIT/binaries/$Version/moonbit-windows-x86_64-dev.zip"
} else {
  $MoonbitUri = "$CLI_MOONBIT/binaries/$Version/moonbit-windows-x86_64.zip"
}

$CoreUri = "$CLI_MOONBIT/cores/core-$Version.zip"


try {
  if (-not (Test-Path -Path $MoonHome -PathType Container)) {
    New-Item -Path $MoonHome -ItemType Directory
  }
  Write-Output "Downloading moonbit ..."
  Invoke-WebRequest -Uri $MoonbitUri -OutFile "${HOME}\moonbit.zip"
  if (Test-Path -Path "$MoonHome\bin" -PathType Container) {
    Remove-Item -Force -Recurse "$MoonHome\bin"
  }
  if (Test-Path -Path "$MoonHome\lib" -PathType Container) {
    Remove-Item -Force -Recurse "$MoonHome\lib"
  }
  if (Test-Path -Path "$MoonHome\include" -PathType Container) {
    Remove-Item -Force -Recurse "$MoonHome\include"
  }
  Expand-Archive "${HOME}\moonbit.zip" -DestinationPath $MoonHome -Force
  Remove-Item -Force "${HOME}\moonbit.zip"

  Write-Output "Downloading core ..."
  if (Test-Path -Path $MoonLib\core) {
    Remove-Item -Force -Recurse $MoonLib\core
  }
  if ($Version -eq "bleeding") {
    # Clone core repository for bleeding version
    git clone --depth 1 https://github.com/moonbitlang/core.git "$MoonLib\core"
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Install Failed:"
        Write-Output "Failed to clone core from github"
        return 1
    }
  } else {
    # Download regular release version
    Invoke-WebRequest -Uri $CoreUri -OutFile $MoonHome\core.zip
    Expand-Archive $MoonHome\core.zip -DestinationPath $MoonLib -Force
    Remove-Item -Force $MoonHome\core.zip
  }

  Write-Output "Bundling core ..."
  Push-Location $MoonLib\core

  $OldPath = $env:Path
  $env:Path = $MoonBin
  moon.exe bundle --all
  moon.exe bundle --target wasm-gc --quiet
  $env:PATH = $OldPath

  Pop-Location
}
catch {
  Write-Output "Install Failed:"
  Write-Output $_.Exception.Message
  return 1
}

if ($env:Path -split ';' -notcontains $MoonBin) {
  $currentPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
  [System.Environment]::SetEnvironmentVariable("PATH", "$MoonBin;$currentPath", [System.EnvironmentVariableTarget]::User)

  Write-Output "Added ~/.moon/bin to the PATH."
  Write-Output "Please restart your terminal to use moonbit."
}
else {
  Write-Output "Moonbit installed successfully."
}

Write-Output "To verify the download binaries, check https://www.moonbitlang.com/download#verifying-binaries for instructions."

Write-Output "To know how to add shell completions, run 'moon shell-completion --help'"