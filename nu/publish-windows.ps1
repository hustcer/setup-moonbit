param([string]$Staged, [string]$Backup, [string]$InstallDir, [switch]$CreateAlias)

$ErrorActionPreference = 'Stop'

if ($CreateAlias) {
    # Use literal paths, including brackets that the PowerShell provider treats as wildcards.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MoonBitHardLink {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern bool CreateHardLinkW(string link, string target, IntPtr security);

    public static void Create(string link, string target) {
        if (!CreateHardLinkW(link, target, IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
    $aliasPath = Join-Path $Staged 'bin\moonx.exe'
    [IO.File]::Delete($aliasPath)
    [MoonBitHardLink]::Create($aliasPath, (Join-Path $Staged 'bin\moon.exe'))
    return
}

function Get-Entry([string]$Path) {
    try { Get-Item -LiteralPath $Path -Force }
    catch [System.Management.Automation.ItemNotFoundException] { $null }
}

function Test-RealDirectory($Entry) {
    $null -ne $Entry -and $Entry.PSIsContainer -and -not ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Move-Entry([string]$Source, [string]$Destination, [bool]$Directory) {
    try {
        if ($Directory) { [IO.Directory]::Move($Source, $Destination) }
        else { [IO.File]::Move($Source, $Destination) }
    }
    catch { throw "Cannot move '$([IO.Path]::GetFileName($Source))' from '$Source' to '$Destination'. $($_.Exception.Message)" }
}

function Move-ForInstall($Entry, [string]$Destination, [switch]$Required) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    Move-Entry $Entry.FullName $Destination $Entry.PSIsContainer
    $moves.Add(@{
        Source = $Entry.FullName
        Destination = $Destination
        Directory = $Entry.PSIsContainer
        Required = $Required.IsPresent
    })
}

function Merge-OldBin([string]$OldDir, [string]$NewDir) {
    foreach ($old in (Get-ChildItem -LiteralPath $OldDir -Force)) {
        $destination = Join-Path $NewDir $old.Name
        $incoming = Get-Entry $destination
        if ($null -eq $incoming) {
            # These paths must be movable, so release their probe handles before moving them.
            Protect-OldImages $old -ProbeOnly
            # Moving extra files preserves their identity, including custom hard links.
            Move-ForInstall $old $destination -Required
        }
        elseif (Test-RealDirectory $old) {
            if (-not (Test-RealDirectory $incoming)) {
                throw "Cannot replace existing directory '$($old.FullName)' with a non-directory archive entry."
            }
            Merge-OldBin $old.FullName $incoming.FullName
        }
    }
}

function Protect-OldImages($Entry, [switch]$ProbeOnly) {
    if ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if ($Entry.PSIsContainer) {
        foreach ($child in (Get-ChildItem -LiteralPath $Entry.FullName -Force)) {
            Protect-OldImages $child -ProbeOnly:$ProbeOnly
        }
    }
    elseif ($Entry.Extension -in '.exe', '.dll') {
        try {
            # Request write access to detect mapped images. Share writes so
            # multiple names of the same file (like moon and moonx) can be held.
            $handle = [IO.File]::Open($Entry.FullName, 'Open', 'Write', 'Write')
        }
        catch {
            throw "Cannot reserve old MoonBit image '$($Entry.Name)'. Close any processes using it and retry. $($_.Exception.Message)"
        }
        if ($ProbeOnly) { $handle.Dispose() }
        else { $images.Add($handle) }
    }
}

function Publish-Entry($Incoming, [string]$Destination, [string]$Previous, [switch]$Replace) {
    $live = Get-Entry $Destination
    if (-not $Replace -and (Test-RealDirectory $live)) {
        if (-not (Test-RealDirectory $Incoming)) {
            throw "Cannot replace existing directory '$Destination' with a non-directory archive entry."
        }
        foreach ($child in (Get-ChildItem -LiteralPath $Incoming.FullName -Force)) {
            Publish-Entry $child (Join-Path $Destination $child.Name) (Join-Path $Previous $child.Name)
        }
    }
    else {
        if ($null -ne $live) { Move-ForInstall $live $Previous -Required:$Replace }
        Move-ForInstall $Incoming $Destination -Required:$Replace
    }
}

# The official installer uses the same file and holds the handle for the update.
# Leave the file in place so successive processes always lock the same file.
$lockPath = Join-Path $InstallDir '.install.lock'
try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] { throw "Cannot acquire .install.lock at '$lockPath'. $($_.Exception.Message)" }

try {
    $roots = 'bin', 'lib', 'include'
    foreach ($name in $roots) {
        $entry = Get-Entry (Join-Path $InstallDir $name)
        if ($null -ne $entry -and -not (Test-RealDirectory $entry)) {
            throw "Cannot replace '$($entry.FullName)' with a directory."
        }
    }

    $liveBin = Join-Path $InstallDir 'bin'
    $oldBin = Join-Path $Backup 'bin'
    $newBin = Join-Path $Staged 'bin'
    $moves = [Collections.Generic.List[hashtable]]::new()
    $images = [Collections.Generic.List[IO.FileStream]]::new()
    # Keep staging if the process is interrupted or rolling back a move fails.
    $pending = Join-Path $Backup '.publish-pending'
    [IO.File]::Open($pending, 'CreateNew').Dispose()
    try {
        try {
            $old = Get-Entry $liveBin
            if ($null -ne $old) {
                try { Move-ForInstall $old $oldBin -Required }
                catch { throw "Cannot move the old MoonBit bin directory. Close any processes using it and retry. $($_.Exception.Message)" }
                Merge-OldBin $oldBin $newBin
                Protect-OldImages (Get-Entry $oldBin)
            }

            foreach ($name in 'lib', 'include') {
                Publish-Entry (Get-Entry (Join-Path $Staged $name)) (Join-Path $InstallDir $name) (Join-Path $Backup $name) -Replace
            }
            foreach ($entry in (Get-ChildItem -LiteralPath $Staged -Force)) {
                if ($entry.Name -notin $roots) {
                    Publish-Entry $entry (Join-Path $InstallDir $entry.Name) (Join-Path $Backup $entry.Name)
                }
            }
            # Make binaries visible only after the matching libraries and headers.
            Move-ForInstall (Get-Entry $newBin) $liveBin -Required
        }
        finally {
            foreach ($handle in $images) { $handle.Dispose() }
        }
    }
    catch {
        $publishError = $_
        $restoreErrors = [Collections.Generic.List[string]]::new()
        $requiredRestoreFailed = $false
        for ($index = $moves.Count - 1; $index -ge 0; $index--) {
            $move = $moves[$index]
            # Keep old binaries private if a required part of the old install could not be restored.
            if ($move.Source -eq $liveBin -and $requiredRestoreFailed) { continue }
            try { Move-Entry $move.Destination $move.Source $move.Directory }
            catch {
                $restoreErrors.Add($_.Exception.Message)
                if ($move.Required) { $requiredRestoreFailed = $true }
                # If new bin is still live, keep its matching lib and include in place.
                if ($move.Destination -eq $liveBin) { break }
            }
        }
        if ($restoreErrors.Count -gt 0) {
            throw "Failed to publish and restore MoonBit. Backup: $Backup. Publish: $publishError. Restore: $($restoreErrors -join '; ')"
        }
        [IO.File]::Delete($pending)
        throw $publishError
    }
    [IO.File]::Delete($pending)
}
finally { $lock.Dispose() }
