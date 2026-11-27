param([string]$Installer)

$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$work = Join-Path $env:TEMP ('setup moonbit test ' + [guid]::NewGuid().ToString('N'))
$homeDir = Join-Path $work 'installed'
$payload = Join-Path $work 'payload'
$mocks = Join-Path $work 'mocks'
$archive = Join-Path $work 'toolchain.zip'
$invalidAliasArchive = Join-Path $work 'invalid-alias.zip'
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

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Installer {
    # Windows PowerShell wraps native stderr in ErrorRecord values.
    $ErrorActionPreference = 'Continue'
    $output = & nu --no-config-file $Installer latest 2>&1
    @{ Code = $LASTEXITCODE; Output = $output -join "`n" }
}

function Assert-OldInstall {
    Assert-True ((Get-FileHash -LiteralPath $oldMoon).Hash -eq $oldHash) 'The old executable changed.'
    Assert-True ((Get-FileHash -LiteralPath $moonx).Hash -eq $oldHash) 'The old moonx alias changed.'
    Assert-True ((Get-FileHash -LiteralPath $legacyTool).Hash -eq $oldHash) 'The legacy tool changed.'
    Assert-True ([IO.File]::ReadAllText($custom) -eq 'custom tool') 'The custom file changed.'
    Assert-True ([IO.File]::ReadAllText($runtime) -eq 'old runtime') 'The old runtime changed.'
    Assert-True ([IO.File]::ReadAllText($header) -eq 'old header') 'The old header changed.'
    Assert-True ([IO.File]::ReadAllText($credits) -eq 'old credits') 'The old credits changed.'
    Assert-NoStaging
}

function Assert-NoStaging {
    $staging = Get-ChildItem -LiteralPath $homeDir -Force | Where-Object Name -Like '.setup-moonbit.*'
    Assert-True ($null -eq $staging) 'A staging directory was left behind.'
}

$environment = @{
    PATH = "$mocks;$env:PATH"
    MOONBIT_HOME = $homeDir
    MOONBIT_INSTALL_DEV = ''
    GITHUB_PATH = Join-Path $work 'github-path'
    TEST_MOONBIT_ARCHIVE = $archive
    TEST_MOONBIT_READY = $ready
}
$previous = @{}
try {
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
            Console.WriteLine("test toolchain version");
            return 0;
        }
        return 2;
    }
}
'@
    [IO.File]::Copy($curl, $oldMoon)
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
    # Appending fixture data leaves the PE runnable and distinguishes it from the old file.
    [IO.File]::AppendAllText($newMoon, 'new version')
    $newHash = (Get-FileHash -LiteralPath $newMoon).Hash
    [IO.File]::WriteAllText((Join-Path $payload 'bin\internal\bundled.txt'), 'bundled tool')
    [IO.File]::WriteAllText((Join-Path $payload 'lib\runtime.c'), 'new runtime')
    [IO.File]::WriteAllText((Join-Path $payload 'include\moonbit.h'), 'new header')
    [IO.File]::WriteAllText((Join-Path $payload 'CREDITS.md'), 'new credits')
    & tar.exe -a -cf $archive -C $payload bin lib include CREDITS.md
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the test archive.'
    [void][IO.Directory]::CreateDirectory((Join-Path $payload 'bin\moonx.exe'))
    & tar.exe -a -cf $invalidAliasArchive -C $payload bin lib include
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the archive with an invalid alias.'

    $env:TEST_MOONBIT_ARCHIVE = $invalidAliasArchive
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and $result.Output.Contains('moonx.exe hard link')) "Expected alias creation to fail. $($result.Output)"
    }
    finally { $env:TEST_MOONBIT_ARCHIVE = $archive }
    Assert-OldInstall

    $conflictDir = Join-Path $work 'path conflict'
    [void][IO.Directory]::CreateDirectory($conflictDir)
    $conflict = Join-Path $conflictDir 'include'
    [IO.File]::WriteAllText($conflict, 'existing file')
    $env:MOONBIT_HOME = $conflictDir
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and $result.Output.Contains('Cannot replace')) "Expected a path conflict. $($result.Output)"
        Assert-True ([IO.File]::ReadAllText($conflict) -eq 'existing file') 'The conflicting file was changed.'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $conflictDir 'bin'))) 'The conflicting install was partially published.'
    }
    finally { $env:MOONBIT_HOME = $homeDir }

    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and $result.Output.Contains('.install.lock')) "Expected lock contention. $($result.Output)"
    }
    finally { $lock.Dispose() }
    Assert-OldInstall

    foreach ($busyExecutable in $oldMoon, $legacyTool) {
        $busy = Start-Process -FilePath $busyExecutable -ArgumentList 'busy' -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not [IO.File]::Exists($ready) -and -not $busy.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            Assert-True ([IO.File]::Exists($ready) -and -not $busy.HasExited) 'The old process did not start.'
            $result = Invoke-Installer
            Assert-True ($result.Code -ne 0 -and $result.Output -match 'old MoonBit (bin directory|image)') "Expected an in-use error. $($result.Output)"
        }
        finally {
            if (-not $busy.HasExited) { $busy.Kill() }
            $busy.WaitForExit()
            $busy.Dispose()
            [IO.File]::Delete($ready)
        }
        Assert-OldInstall
    }

    # This file is replaced after bin is withdrawn and after lib/include are published.
    $heldCredits = [IO.File]::Open($credits, 'Open', 'Read', 'Read')
    try {
        $result = Invoke-Installer
        Assert-True ($result.Code -ne 0 -and $result.Output.Contains('CREDITS.md')) "Expected a late replacement failure. $($result.Output)"
    }
    finally { $heldCredits.Dispose() }
    Assert-OldInstall

    $result = Invoke-Installer
    Assert-True ($result.Code -eq 0 -and $result.Output.Contains('test toolchain version')) "Expected a successful retry. $($result.Output)"
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
}
finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    if ([IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work, $true) }
}
