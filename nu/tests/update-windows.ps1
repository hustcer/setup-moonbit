param([string]$Installer)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $Installer).Path
$work = Join-Path $env:TEMP ('setup moonbit test ' + [guid]::NewGuid().ToString('N'))
$Installer = Join-Path $work 'moonbit.nu'
$homeDir = Join-Path $work 'installed'
$payload = Join-Path $work 'payload'
$mocks = Join-Path $work 'mocks'
$archive = Join-Path $work 'toolchain.zip'
$incompleteArchive = Join-Path $work 'incomplete.zip'
$missingCompilerArchive = Join-Path $work 'missing-moonc.zip'
$missingRunnerArchive = Join-Path $work 'missing-moonrun.zip'
$invalidAliasArchive = Join-Path $work 'invalid-alias.zip'
$invalidMoonArchive = Join-Path $work 'invalid-moon.zip'
$conflictingArchive = Join-Path $work 'conflicting.zip'
$ready = Join-Path $work 'ready'
$oldMoon = Join-Path $homeDir 'bin\moon.exe'
$legacyTool = Join-Path $homeDir 'bin\legacy.exe'
$moonx = Join-Path $homeDir 'bin\moonx.exe'
$custom = Join-Path $homeDir 'bin\internal\custom.txt'
$customLink = Join-Path $work 'custom-link.txt'
$runtime = Join-Path $homeDir 'lib\runtime.c'
$header = Join-Path $homeDir 'include\moonbit.h'
$credits = Join-Path $homeDir 'CREDITS.md'
$lockPath = Join-Path $homeDir '.install.lock'
$oldBin = Join-Path $homeDir 'bin'
$oldCompiler = Join-Path $oldBin 'moonc.exe'
$oldRunner = Join-Path $oldBin 'moonrun.exe'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Installer {
    # Windows PowerShell wraps native stderr in ErrorRecord values.
    $ErrorActionPreference = 'Continue'
    $output = & nu --no-config-file $Installer latest 2>&1
    @{ Code = $LASTEXITCODE; Output = $output -join "`n" }
}

function ConvertTo-CompactDiagnostic([string]$Text) {
    ($Text -replace '\x1B\[[0-?]*[ -/]*[@-~]', '') -replace '[\s|\u2502]+', ''
}

function Test-InstallerDiagnostic($Result, [string]$Expected) {
    (ConvertTo-CompactDiagnostic $Result.Output).Contains((ConvertTo-CompactDiagnostic $Expected))
}

function Assert-OldInstall {
    Assert-True ((Get-FileHash -LiteralPath $oldMoon).Hash -eq $oldHash) 'The old executable changed.'
    Assert-True ((Get-FileHash -LiteralPath $oldCompiler).Hash -eq $oldHash) 'The old compiler changed.'
    Assert-True ((Get-FileHash -LiteralPath $oldRunner).Hash -eq $oldHash) 'The old runner changed.'
    Assert-True ((Get-FileHash -LiteralPath $moonx).Hash -eq $oldHash) 'The old moonx alias changed.'
    Assert-True ((Get-FileHash -LiteralPath $legacyTool).Hash -eq $oldHash) 'The legacy tool changed.'
    Assert-True ([IO.File]::ReadAllText($custom) -eq 'custom tool') 'The custom file changed.'
    Assert-True ([IO.File]::ReadAllText($runtime) -eq 'old runtime') 'The old runtime changed.'
    Assert-True ([IO.File]::ReadAllText($header) -eq 'old header') 'The old header changed.'
    Assert-True ([IO.File]::ReadAllText($credits) -eq 'old credits') 'The old credits changed.'
    Assert-NoStaging
}

function Assert-NoStaging([string]$Root = $homeDir) {
    $staging = Get-ChildItem -LiteralPath $Root -Force | Where-Object Name -Like '.setup-moonbit.*'
    Assert-True ($null -eq $staging) "A staging directory was left behind in '$Root'."
}

function Assert-BusyInstall([string]$Executable) {
    $busy = Start-Process -FilePath $Executable -ArgumentList 'busy' -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not [IO.File]::Exists($ready) -and -not $busy.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True ([IO.File]::Exists($ready) -and -not $busy.HasExited) "The old process did not start from '$Executable'."
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and (Test-InstallerDiagnostic $result 'Close any processes using it')) "Expected an in-use error for '$Executable'. $($result.Output)"
    }
    finally {
        if (-not $busy.HasExited) { $busy.Kill() }
        $busy.WaitForExit()
        $busy.Dispose()
        [IO.File]::Delete($ready)
    }
    Assert-OldInstall
}

$environment = @{
    PATH = "$mocks;$oldBin;$env:PATH"
    MOONBIT_HOME = $homeDir
    MOONBIT_INSTALL_DEV = ''
    MOONC_OVERRIDE = $oldCompiler
    MOONRUN_OVERRIDE = $oldRunner
    GITHUB_PATH = Join-Path $work 'github-path'
    TEST_MOONBIT_ARCHIVE = $archive
    TEST_MOONBIT_READY = $ready
}
$previous = @{}
try {
    [void][IO.Directory]::CreateDirectory($work)
    [IO.File]::Copy($source, $Installer)
    [IO.File]::Copy((Join-Path (Split-Path -Parent $source) 'publish-windows.ps1'), (Join-Path $work 'publish-windows.ps1'))
    [IO.File]::Copy((Join-Path $PSScriptRoot 'fixtures\download.nu'), (Join-Path $work 'download.nu'))
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $environment[$name])
    }
    foreach ($dir in 'bin\internal', 'lib', 'include') {
        [void][IO.Directory]::CreateDirectory((Join-Path $homeDir $dir))
        [void][IO.Directory]::CreateDirectory((Join-Path $payload $dir))
    }
    [void][IO.Directory]::CreateDirectory($mocks)
    $curl = Join-Path $mocks 'curl.exe'
    # One native test executable can simulate curl and a running Moon process.
    Add-Type -OutputAssembly $curl -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;

public static class MoonBitFixture {
    public static int Main(string[] args) {
        int output = Array.IndexOf(args, "-o");
        if (output >= 0) {
            File.Copy(Environment.GetEnvironmentVariable("TEST_MOONBIT_ARCHIVE"), args[output + 1]);
            return 0;
        }
        if (args.Length == 1 && args[0] == "busy") {
            File.WriteAllText(Environment.GetEnvironmentVariable("TEST_MOONBIT_READY"), "");
            Thread.Sleep(60000);
            return 0;
        }
        if (args.Length == 2 && args[0] == "version" && args[1] == "--all") {
            string root = Environment.GetEnvironmentVariable("MOON_HOME");
            if (!String.Equals(Environment.GetEnvironmentVariable("MOONC_OVERRIDE"), Path.Combine(root, "bin", "moonc.exe"), StringComparison.OrdinalIgnoreCase)) return 3;
            if (!String.Equals(Environment.GetEnvironmentVariable("MOONRUN_OVERRIDE"), Path.Combine(root, "bin", "moonrun.exe"), StringComparison.OrdinalIgnoreCase)) return 3;
            Console.WriteLine("test toolchain version");
            return 0;
        }
        return 2;
    }
}
'@
    [IO.File]::Copy($curl, $oldMoon)
    [IO.File]::Copy($curl, $oldCompiler)
    [IO.File]::Copy($curl, $oldRunner)
    [IO.File]::Copy($curl, $legacyTool)
    New-Item -ItemType HardLink -Path $moonx -Value $oldMoon | Out-Null
    [IO.File]::WriteAllText($custom, 'custom tool')
    New-Item -ItemType HardLink -Path $customLink -Value $custom | Out-Null
    [IO.File]::WriteAllText($runtime, 'old runtime')
    [IO.File]::WriteAllText($header, 'old header')
    [IO.File]::WriteAllText($credits, 'old credits')
    $oldHash = (Get-FileHash -LiteralPath $oldMoon).Hash

    $newMoon = Join-Path $payload 'bin\moon.exe'
    [IO.File]::Copy($curl, $newMoon)
    [IO.File]::Copy($curl, (Join-Path $payload 'bin\moonc.exe'))
    [IO.File]::Copy($curl, (Join-Path $payload 'bin\moonrun.exe'))
    # Appending fixture data leaves the PE runnable and distinguishes it from the old file.
    [IO.File]::AppendAllText($newMoon, 'new version')
    $newHash = (Get-FileHash -LiteralPath $newMoon).Hash
    [IO.File]::WriteAllText((Join-Path $payload 'bin\internal\bundled.txt'), 'bundled tool')
    [IO.File]::WriteAllText((Join-Path $payload 'lib\runtime.c'), 'new runtime')
    [IO.File]::WriteAllText((Join-Path $payload 'include\moonbit.h'), 'new header')
    [IO.File]::WriteAllText((Join-Path $payload 'CREDITS.md'), 'new credits')
    & tar.exe -a -cf $archive -C $payload bin lib include CREDITS.md
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the test archive.'
    & tar.exe -a -cf $incompleteArchive -C $payload bin
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the incomplete archive.'
    & tar.exe -a -cf $missingCompilerArchive --exclude bin/moonc.exe -C $payload bin lib include
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the archive without moonc.exe.'
    & tar.exe -a -cf $missingRunnerArchive --exclude bin/moonrun.exe -C $payload bin lib include
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the archive without moonrun.exe.'
    $invalidAlias = Join-Path $payload 'bin\moonx.exe'
    [void][IO.Directory]::CreateDirectory($invalidAlias)
    & tar.exe -a -cf $invalidAliasArchive -C $payload bin lib include
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the archive with an invalid alias.'
    [IO.Directory]::Delete($invalidAlias)
    $validMoonBytes = [IO.File]::ReadAllBytes($newMoon)
    [IO.File]::WriteAllText($newMoon, 'invalid executable')
    & tar.exe -a -cf $invalidMoonArchive -C $payload bin lib include
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the archive with an invalid executable.'
    [IO.File]::WriteAllBytes($newMoon, $validMoonBytes)
    $payloadInternal = Join-Path $payload 'bin\internal'
    [IO.Directory]::Delete($payloadInternal, $true)
    [IO.File]::WriteAllText($payloadInternal, 'unexpected replacement')
    & tar.exe -a -cf $conflictingArchive -C $payload bin lib include CREDITS.md
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the conflicting archive.'

    foreach ($invalidCase in @(
        @{ Archive = $incompleteArchive; Expected = 'Expected a directory'; Label = 'incomplete archive' }
        @{ Archive = $missingCompilerArchive; Expected = 'named moonc.exe'; Label = 'missing compiler' }
        @{ Archive = $missingRunnerArchive; Expected = 'named moonrun.exe'; Label = 'missing runner' }
        @{ Archive = $invalidAliasArchive; Expected = 'moonx.exe hard link'; Label = 'invalid alias' }
        @{ Archive = $invalidMoonArchive; Expected = 'staged Moon'; Label = 'invalid executable' }
    )) {
        $env:TEST_MOONBIT_ARCHIVE = $invalidCase.Archive
        try {
            $result = Invoke-Installer
            Assert-True ($result.Code -ne 0 -and (Test-InstallerDiagnostic $result $invalidCase.Expected)) "Expected $($invalidCase.Label) to fail. $($result.Output)"
        }
        finally { $env:TEST_MOONBIT_ARCHIVE = $archive }
        Assert-OldInstall
    }

    $conflictDir = Join-Path $work 'path conflict'
    [void][IO.Directory]::CreateDirectory($conflictDir)
    $conflict = Join-Path $conflictDir 'include'
    [IO.File]::WriteAllText($conflict, 'existing file')
    $env:MOONBIT_HOME = $conflictDir
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and (Test-InstallerDiagnostic $result 'Cannot replace')) "Expected a path conflict. $($result.Output)"
        Assert-True ([IO.File]::ReadAllText($conflict) -eq 'existing file') 'The conflicting file was changed.'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $conflictDir 'bin'))) 'The conflicting install was partially published.'
        Assert-NoStaging $conflictDir
    }
    finally { $env:MOONBIT_HOME = $homeDir }

    $env:TEST_MOONBIT_ARCHIVE = $conflictingArchive
    try {
        $result = Invoke-Installer
        $compactOutput = ConvertTo-CompactDiagnostic $result.Output
        Assert-True (
            $result.Code -ne 0 -and
            $compactOutput.Contains((ConvertTo-CompactDiagnostic 'only one entry is a directory')) -and
            $compactOutput.Contains('installed\bin\internal') -and
            -not $compactOutput.Contains('backup\bin\internal')
        ) "Expected a bin subdirectory conflict referencing the live path. $($result.Output)"
    }
    finally { $env:TEST_MOONBIT_ARCHIVE = $archive }
    Assert-OldInstall

    $fileConflictHome = Join-Path $work 'file conflict'
    $fileConflict = Join-Path $fileConflictHome 'bin\internal'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fileConflict))
    [IO.File]::WriteAllText($fileConflict, 'user file')
    $env:MOONBIT_HOME = $fileConflictHome
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and (Test-InstallerDiagnostic $result 'Cannot replace')) "Expected a file and directory conflict. $($result.Output)"
        Assert-True ([IO.File]::ReadAllText($fileConflict) -eq 'user file') 'The conflicting user file was changed.'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $fileConflictHome 'lib'))) 'The conflicting install was partially published.'
        Assert-NoStaging $fileConflictHome
    }
    finally { $env:MOONBIT_HOME = $homeDir }

    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and (Test-InstallerDiagnostic $result '.install.lock')) "Expected lock contention. $($result.Output)"
    }
    finally { $lock.Dispose() }
    Assert-OldInstall

    $interrupted = Join-Path $homeDir '.setup-moonbit.interrupted'
    $interruptedBackup = Join-Path $interrupted 'backup'
    $interruptedBin = Join-Path $interruptedBackup 'bin'
    $pending = Join-Path $interruptedBackup '.publish-pending'
    [void][IO.Directory]::CreateDirectory($interruptedBackup)
    [IO.File]::WriteAllText($pending, '')
    [IO.Directory]::Move($oldBin, $interruptedBin)
    try {
        $result = Invoke-Installer
        $compactOutput = ConvertTo-CompactDiagnostic $result.Output
        Assert-True ($result.Code -ne 0 -and $compactOutput.Contains('.setup-moonbit.interrupted\backup')) "Expected recovery instructions. $($result.Output)"
        Assert-True (-not [IO.Directory]::Exists($oldBin)) 'Retry published a new bin over the interrupted update.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $interruptedBin 'internal\custom.txt')) -eq 'custom tool') 'Retry changed the saved custom tool.'
        Assert-True ([IO.File]::Exists($pending)) 'Retry removed the recovery marker.'
        $staging = @(Get-ChildItem -LiteralPath $homeDir -Force -Filter '.setup-moonbit.*')
        Assert-True ($staging.Count -eq 1) 'Retry left an additional staging directory.'
    }
    finally {
        if (-not [IO.Directory]::Exists($oldBin)) {
            [IO.Directory]::Move($interruptedBin, $oldBin)
            [IO.Directory]::Delete($interrupted, $true)
        }
    }
    Assert-OldInstall

    Assert-BusyInstall $oldMoon
    Assert-BusyInstall $legacyTool
    $legacyAttributes = [IO.File]::GetAttributes($legacyTool)
    [IO.File]::SetAttributes($legacyTool, ($legacyAttributes -bor [IO.FileAttributes]::ReadOnly))
    try { Assert-BusyInstall $legacyTool }
    finally { [IO.File]::SetAttributes($legacyTool, $legacyAttributes) }

    # This file is replaced after bin is withdrawn and after lib/include are published.
    $heldCredits = [IO.File]::Open($credits, 'Open', 'Read', 'Read')
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and (Test-InstallerDiagnostic $result 'CREDITS.md')) "Expected a late replacement failure. $($result.Output)"
    }
    finally { $heldCredits.Dispose() }
    Assert-OldInstall

    # Force a required rollback move to fail after lib and include have gone live.
    $rollbackHome = Join-Path $work 'rollback failure'
    $rollbackWork = Join-Path $rollbackHome '.setup-moonbit.rollback'
    $rollbackStage = Join-Path $rollbackWork 'toolchain'
    $rollbackBackup = Join-Path $rollbackWork 'backup'
    $stagedLib = Join-Path $rollbackStage 'lib'
    $publisher = Join-Path (Split-Path -Parent $Installer) 'publish-windows.ps1'
    [void][IO.Directory]::CreateDirectory($rollbackBackup)
    foreach ($root in $rollbackHome, $rollbackStage) {
        foreach ($dir in 'bin', 'lib', 'include') {
            [void][IO.Directory]::CreateDirectory((Join-Path $root $dir))
        }
        [IO.File]::WriteAllText((Join-Path $root 'bin\moon.exe'), $root)
        [IO.File]::WriteAllText((Join-Path $root 'lib\runtime.c'), $root)
    }
    $restoreError = & {
        function Get-ChildItem([string]$LiteralPath, [string]$Filter, [switch]$Force) {
            if ($LiteralPath -eq $rollbackStage -and -not [IO.Directory]::Exists($stagedLib)) {
                [void][IO.Directory]::CreateDirectory($stagedLib)
                throw 'Injected late publication failure.'
            }
            Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
        }
        try { & $publisher -Staged $rollbackStage -Backup $rollbackBackup -InstallDir $rollbackHome }
        catch { $_.Exception.Message }
    }
    Assert-True ($restoreError -like '*Failed to publish and restore MoonBit*') "Expected failed restoration. $restoreError"
    Assert-True (-not [IO.Directory]::Exists((Join-Path $rollbackHome 'bin'))) 'Rollback exposed old binaries alongside the new lib directory.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $rollbackBackup 'bin\moon.exe')) -eq $rollbackHome) 'Rollback lost the old executable.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $rollbackBackup 'lib\runtime.c')) -eq $rollbackHome) 'Rollback lost the old runtime.'
    Assert-True ([IO.File]::Exists((Join-Path $rollbackBackup '.publish-pending'))) 'Rollback lost the recovery marker.'

    $moonAttributes = [IO.File]::GetAttributes($oldMoon)
    [IO.File]::SetAttributes($oldMoon, ($moonAttributes -bor [IO.FileAttributes]::ReadOnly))
    try {
        $result = Invoke-Installer
        $compactOutput = ConvertTo-CompactDiagnostic $result.Output
        Assert-True (
            $result.Code -ne 0 -and (Test-InstallerDiagnostic $result 'Access denied while reserving') -and
            $compactOutput.Contains('installed\bin\moon') -and -not $compactOutput.Contains('backup\bin\moon')
        ) "Expected a permissions error referencing the installed image. $($result.Output)"
        Assert-OldInstall
    }
    finally { [IO.File]::SetAttributes($oldMoon, $moonAttributes) }

    [IO.File]::SetAttributes($legacyTool, ($legacyAttributes -bor [IO.FileAttributes]::ReadOnly))
    $env:MOONC_OVERRIDE = Join-Path $work 'absent-moonc.exe'
    $env:MOONRUN_OVERRIDE = Join-Path $work 'absent-moonrun.exe'
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -eq 0 -and (Test-InstallerDiagnostic $result 'test toolchain version')) "Expected a successful retry with a read-only custom tool. $($result.Output)"
        Assert-True (([IO.File]::GetAttributes($legacyTool) -band [IO.FileAttributes]::ReadOnly) -ne 0) 'The custom tool lost its read-only attribute.'
    }
    finally {
        [IO.File]::SetAttributes($legacyTool, $legacyAttributes)
        $env:MOONC_OVERRIDE = $oldCompiler
        $env:MOONRUN_OVERRIDE = $oldRunner
    }
    Assert-True ((Get-FileHash -LiteralPath $oldMoon).Hash -eq $newHash) 'The new executable was not published.'
    Assert-True ((Get-FileHash -LiteralPath $legacyTool).Hash -eq $oldHash) 'The legacy tool was not preserved.'
    Assert-True ([IO.File]::ReadAllText($runtime) -eq 'new runtime') 'The new runtime was not published.'
    Assert-True ([IO.File]::ReadAllText($header) -eq 'new header') 'The new header was not published.'
    Assert-True ([IO.File]::ReadAllText($credits) -eq 'new credits') 'The new credits were not published.'
    Assert-True ([IO.File]::Exists((Join-Path $homeDir 'bin\internal\bundled.txt'))) 'The bundled tool was not published.'
    [IO.File]::AppendAllText($oldMoon, 'hard link probe')
    Assert-True ((Get-FileHash -LiteralPath $moonx).Hash -eq (Get-FileHash -LiteralPath $oldMoon).Hash) 'moonx is not a hard link to the new moon.'
    [IO.File]::AppendAllText($customLink, '!')
    Assert-True ([IO.File]::ReadAllText($custom) -eq 'custom tool!') 'The custom hard link was not preserved.'
    Assert-NoStaging

    $bracketHome = Join-Path $work 'installed [local]'
    $env:MOONBIT_HOME = $bracketHome
    $result = Invoke-Installer
    Assert-True ($result.Code -eq 0) "Expected a successful install with brackets in the path. $($result.Output)"
    Assert-True ([IO.File]::Exists((Join-Path $bracketHome 'bin\moonx.exe'))) 'The alias is missing from the bracket path.'
    Assert-NoStaging $bracketHome

    $bracketCustom = Join-Path $bracketHome 'bin\internal\bracket-custom.txt'
    [IO.File]::WriteAllText($bracketCustom, 'bracket custom tool')
    $result = Invoke-Installer
    Assert-True ($result.Code -eq 0) "Expected a successful upgrade with brackets in the path. $($result.Output)"
    Assert-True ([IO.File]::Exists((Join-Path $bracketHome 'bin\moonx.exe'))) 'The alias is missing after upgrading the bracket path.'
    Assert-True ([IO.File]::ReadAllText($bracketCustom) -eq 'bracket custom tool') 'The custom file was lost when upgrading the bracket path.'
    Assert-NoStaging $bracketHome
}
finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    if ([IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work, $true) }
}
