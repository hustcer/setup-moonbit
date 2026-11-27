#!/usr/bin/env pwsh
if ($env:MOONBIT_INSTALL_VERSION) {
  $Version = $env:MOONBIT_INSTALL_VERSION
}
else {
  $Version = "latest"
}
$Version = $Version -replace '\+', '%2B'

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITECTURE -ne "ARM64") {
  Write-Output "Install Failed:"
  Write-Output "MoonBit for Windows is currently only available for x86 64-bit && ARM 64-bit Windows.`n"
  exit 1
}

$ErrorActionPreference = "Stop"
$oldMoonHome = $env:MOON_HOME
if ($env:MOON_HOME) {
  $MoonHome = $env:MOON_HOME
}
else {
  $MoonHome = Join-Path $HOME ".moon"
}
$MoonHome = [System.IO.Path]::GetFullPath($MoonHome)
$MoonBin = Join-Path $MoonHome "bin"
$MoonExe = "${MoonBin}\moon.exe"
$MoonxExe = "${MoonBin}\moonx.exe"

$CLI_MOONBIT = "https://cli.moonbitlang.com"
if ($env:MOONBIT_INSTALL_DEV) {
  $MoonbitUri = "$CLI_MOONBIT/binaries/$Version/moonbit-windows-x86_64-dev.zip"
}
else {
  $MoonbitUri = "$CLI_MOONBIT/binaries/$Version/moonbit-windows-x86_64.zip"
}
$CoreUri = "$CLI_MOONBIT/cores/core-$Version.zip"

$oldPreference = $ProgressPreference
$oldPath = $env:Path
$ProgressPreference = "SilentlyContinue"
$installLock = $null
$stageRoot = $null
$safeToClean = $true

try {
  [void][System.IO.Directory]::CreateDirectory($MoonHome)
  try {
    $installLock = [System.IO.File]::Open(
      (Join-Path $MoonHome ".install.lock"),
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  }
  catch [System.IO.IOException] {
    throw "Another MoonBit installation is already running."
  }

  # Staging inside MOON_HOME keeps publication moves on the same volume.
  $stageRoot = Join-Path $MoonHome (".install-" + [System.Guid]::NewGuid().ToString("N"))
  $newRoot = Join-Path $stageRoot "new"
  $backupRoot = Join-Path $stageRoot "backup"
  [void][System.IO.Directory]::CreateDirectory($newRoot)
  [void][System.IO.Directory]::CreateDirectory($backupRoot)

  Write-Output "Downloading moonbit ..."
  $moonbitArchive = Join-Path $stageRoot "moonbit.zip"
  Invoke-WebRequest -Uri $MoonbitUri -OutFile $moonbitArchive
  Expand-Archive -LiteralPath $moonbitArchive -DestinationPath $newRoot

  $newBin = Join-Path $newRoot "bin"
  $newLib = Join-Path $newRoot "lib"
  $newInclude = Join-Path $newRoot "include"
  $newMoon = Join-Path $newBin "moon.exe"
  if (
    -not [System.IO.File]::Exists($newMoon) -or
    -not [System.IO.Directory]::Exists($newLib) -or
    -not [System.IO.Directory]::Exists($newInclude)
  ) {
    throw "The downloaded MoonBit archive is incomplete."
  }

  Write-Output "Downloading core ..."
  $coreArchive = Join-Path $stageRoot "core.zip"
  Invoke-WebRequest -Uri $CoreUri -OutFile $coreArchive
  Expand-Archive -LiteralPath $coreArchive -DestinationPath $newLib

  $newCore = Join-Path $newLib "core"
  if (-not [System.IO.Directory]::Exists($newCore)) {
    throw "The downloaded MoonBit core archive is incomplete."
  }

  Write-Output "Bundling core ..."
  Push-Location $newCore
  try {
    $env:Path = $newBin
    $env:MOON_HOME = $newRoot
    & $newMoon bundle --warn-list -a --all
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to bundle MoonBit core."
    }
    & $newMoon bundle --warn-list -a --target wasm-gc --quiet
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to bundle MoonBit core for the wasm-gc target."
    }
  }
  finally {
    $env:Path = $oldPath
    $env:MOON_HOME = $oldMoonHome
    Pop-Location
  }

  # Copy the old bin first, then overlay the package. This preserves additional
  # user-installed binaries while letting bin publish as one directory.
  $mergedBin = Join-Path $stageRoot "merged-bin"
  if ([System.IO.Directory]::Exists($MoonBin)) {
    Copy-Item -LiteralPath $MoonBin -Destination $mergedBin -Recurse -Force
  }
  else {
    [void][System.IO.Directory]::CreateDirectory($mergedBin)
  }
  Copy-Item -Path (Join-Path $newBin "*") -Destination $mergedBin -Recurse -Force
  Remove-Item -LiteralPath $newBin -Recurse -Force
  [System.IO.Directory]::Move($mergedBin, $newBin)

  # Copy-Item does not preserve hard links. Recreate moonx.exe after merging so
  # the published alias points at the newly downloaded moon.exe.
  $newMoonx = Join-Path $newBin "moonx.exe"
  if (Test-Path -LiteralPath $newMoonx) {
    Remove-Item -LiteralPath $newMoonx -Force
  }
  New-Item -ItemType HardLink -Path $newMoonx -Value $newMoon | Out-Null

  $directoryNames = @("lib", "include", "bin")
  $safeToClean = $false
  try {
    $imageHandles = @()
    try {
      # Withdraw public executables, then keep every old native image open until
      # the replacement bin is visible.
      if ([System.IO.Directory]::Exists($MoonBin)) {
        $oldBin = Join-Path $backupRoot "bin"
        [System.IO.Directory]::Move($MoonBin, $oldBin)
        foreach ($file in @(Get-ChildItem -LiteralPath $oldBin -Recurse -File)) {
          if ($file.Extension -ieq ".exe" -or $file.Extension -ieq ".dll") {
            try {
              $fileShare = [System.IO.FileShare]::None
              if ($file.Name -ieq "moon.exe" -or $file.Name -ieq "moonx.exe") {
                # These names may refer to the same file. Write sharing lets us
                # hold both handles while still denying the reads needed to run it.
                $fileShare = [System.IO.FileShare]::Write
              }
              $imageHandles += [System.IO.File]::Open(
                $file.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write,
                $fileShare
              )
            }
            catch {
              throw "MoonBit is currently in use ('$($file.Name)'). Close it and try again."
            }
          }
        }
      }

      foreach ($name in @("lib", "include")) {
        $live = Join-Path $MoonHome $name
        if ([System.IO.File]::Exists($live)) {
          throw "Cannot replace file '$live' with a directory."
        }
        if ([System.IO.Directory]::Exists($live)) {
          [System.IO.Directory]::Move($live, (Join-Path $backupRoot $name))
        }
      }
      foreach ($name in $directoryNames) {
        [System.IO.Directory]::Move(
          (Join-Path $newRoot $name),
          (Join-Path $MoonHome $name)
        )
      }
    }
    finally {
      foreach ($handle in $imageHandles) {
        $handle.Dispose()
      }
    }
    $safeToClean = $true
  }
  catch {
    $publishFailure = $_
    foreach ($name in $directoryNames) {
      $live = Join-Path $MoonHome $name
      $backup = Join-Path $backupRoot $name
      $staged = Join-Path $newRoot $name
      if ([System.IO.Directory]::Exists($backup)) {
        if ([System.IO.Directory]::Exists($live)) {
          [System.IO.Directory]::Move($live, $staged)
        }
        [System.IO.Directory]::Move($backup, $live)
      }
      elseif (-not [System.IO.Directory]::Exists($staged) -and [System.IO.Directory]::Exists($live)) {
        [System.IO.Directory]::Move($live, $staged)
      }
    }
    $safeToClean = $true
    throw $publishFailure
  }

  Copy-Item -Path (Join-Path $newRoot "*") -Destination $MoonHome -Force -ErrorAction Continue
}
catch {
  Write-Output "Install Failed:"
  Write-Output $_.Exception.Message
  exit 1
}
finally {
  $env:Path = $oldPath
  $env:MOON_HOME = $oldMoonHome
  $ProgressPreference = $oldPreference
  if ($stageRoot -and $safeToClean -and [System.IO.Directory]::Exists($stageRoot)) {
    try {
      Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    catch {
      Write-Warning "Failed to remove the installation staging directory."
    }
  }
  if ($installLock) {
    $installLock.Dispose()
  }
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

Write-Output "To verify the downloaded binaries, check https://www.moonbitlang.com/download#verifying-binaries for instructions."
Write-Output "To know how to add shell completions, run 'moon shell-completion --help'"
