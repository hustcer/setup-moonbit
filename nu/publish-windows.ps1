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

function Move-ForInstall($Entry, [string]$Destination, [switch]$Required, [switch]$OldBin, [switch]$NewBin) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    Move-Entry $Entry.FullName $Destination $Entry.PSIsContainer
    $moves.Add(@{
        Source = $Entry.FullName
        Destination = $Destination
        Directory = $Entry.PSIsContainer
        Required = $Required.IsPresent
        OldBin = $OldBin.IsPresent
        NewBin = $NewBin.IsPresent
    })
}

function Assert-MergeEntry($Incoming, $Existing, [string]$LivePath) {
    if ($null -ne $Existing -and (Test-RealDirectory $Existing) -ne (Test-RealDirectory $Incoming)) {
        throw "Cannot replace '$LivePath' because only one entry is a directory."
    }
}

function Assert-MergeLayout($Incoming, [string]$Destination) {
    $live = Get-Entry $Destination
    Assert-MergeEntry $Incoming $live $Destination
    if (Test-RealDirectory $live) {
        foreach ($child in (Get-ChildItem -LiteralPath $Incoming.FullName -Force)) {
            Assert-MergeLayout $child (Join-Path $Destination $child.Name)
        }
    }
}

function Merge-OldBin([string]$OldDir, [string]$NewDir, [string]$LiveDir) {
    foreach ($old in (Get-ChildItem -LiteralPath $OldDir -Force)) {
        $destination = Join-Path $NewDir $old.Name
        $livePath = Join-Path $LiveDir $old.Name
        $incoming = Get-Entry $destination
        if ($null -eq $incoming) {
            # These paths must be movable, so release their probe handles before moving them.
            Protect-OldImages $old $livePath -ProbeOnly
            # Moving extra files preserves their identity, including custom hard links.
            Move-ForInstall $old $destination -Required
        }
        else {
            Assert-MergeEntry $incoming $old $livePath
            if (Test-RealDirectory $old) {
                Merge-OldBin $old.FullName $incoming.FullName $livePath
            }
        }
    }
}

function Test-ImageInUse([string]$Path, [string]$LivePath) {
    if (-not ('MoonBitImageUsage' -as [type])) {
        # cspell:words ntdll ntstatus
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

public static class MoonBitImageUsage {
    [StructLayout(LayoutKind.Sequential)]
    struct IoStatusBlock {
        public IntPtr Status;
        public IntPtr Information;
    }

    [DllImport("ntdll.dll", ExactSpelling = true)]
    static extern uint NtQueryInformationFile(SafeFileHandle file, out IoStatusBlock ioStatus,
        IntPtr information, int length, int informationClass);

    public static bool IsInUse(string path) {
        const int ProcessIdsUsingFile = 47;
        const int BufferSize = 4096;
        using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var process = Process.GetCurrentProcess()) {
            IntPtr buffer = Marshal.AllocHGlobal(BufferSize);
            try {
                IoStatusBlock ioStatus;
                uint status = NtQueryInformationFile(file.SafeFileHandle, out ioStatus, buffer, BufferSize, ProcessIdsUsingFile);
                // A full buffer already implies that processes besides this one are using the file.
                if (status == 0x80000005 || status == 0xC0000023 || status == 0xC0000004) return true;
                if (status != 0) throw new IOException("File usage query failed (NTSTATUS 0x" + status.ToString("X8") + ").");

                int count = Marshal.ReadInt32(buffer);
                for (int index = 1; index <= count; index++) {
                    if (Marshal.ReadIntPtr(buffer, index * IntPtr.Size).ToInt64() != process.Id) return true;
                }
                return false;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}
'@
    }
    try { [MoonBitImageUsage]::IsInUse($Path) }
    catch { throw "Cannot check whether old MoonBit image '$LivePath' is in use. $($_.Exception.GetBaseException().Message)" }
}

function Protect-OldImages($Entry, [string]$LivePath, [switch]$ProbeOnly) {
    if ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if ($Entry.PSIsContainer) {
        foreach ($child in (Get-ChildItem -LiteralPath $Entry.FullName -Force)) {
            Protect-OldImages $child (Join-Path $LivePath $child.Name) -ProbeOnly:$ProbeOnly
        }
    }
    elseif ($Entry.Extension -in '.exe', '.dll') {
        try {
            # Request write access to detect mapped images. Share writes so
            # multiple names of the same file (like moon and moonx) can be held.
            $handle = [IO.File]::Open($Entry.FullName, 'Open', 'Write', 'Write')
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -is [UnauthorizedAccessException]) {
                if (-not $ProbeOnly) {
                    throw "Access denied while reserving old MoonBit image '$LivePath'. Check its permissions and read-only attribute."
                }
                # For a custom tool, check mapped images without requesting write access.
                if (-not (Test-ImageInUse $Entry.FullName $LivePath)) { return }
                throw "Cannot reserve old MoonBit image '$LivePath'. Close any processes using it and retry."
            }
            throw "Cannot reserve old MoonBit image '$LivePath'. Close any processes using it and retry. $($cause.Message)"
        }
        if ($ProbeOnly) { $handle.Dispose() }
        else { $images.Add($handle) }
    }
}

function Publish-Entry($Incoming, [string]$Destination, [string]$Previous, [switch]$Replace) {
    $live = Get-Entry $Destination
    if (-not $Replace) { Assert-MergeEntry $Incoming $live $Destination }
    if (-not $Replace -and (Test-RealDirectory $live)) {
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
    # An interrupted publisher can leave the only copies of user tools in staging.
    foreach ($entry in (Get-ChildItem -LiteralPath $InstallDir -Force -Filter '.setup-moonbit.*')) {
        if (-not (Test-RealDirectory $entry)) { continue }
        $previousBackup = Join-Path $entry.FullName 'backup'
        if ($null -ne (Get-Entry (Join-Path $previousBackup '.publish-pending'))) {
            throw "An earlier MoonBit publication is incomplete. Recover the installation from the preserved staging directory '$($entry.FullName)' and backup '$previousBackup' before retrying."
        }
    }

    $roots = 'bin', 'lib', 'include'
    foreach ($name in $roots) {
        $entry = Get-Entry (Join-Path $InstallDir $name)
        if ($null -ne $entry -and -not (Test-RealDirectory $entry)) {
            throw "Cannot replace '$($entry.FullName)' with a directory."
        }
    }
    foreach ($entry in (Get-ChildItem -LiteralPath $Staged -Force)) {
        if ($entry.Name -notin 'lib', 'include') {
            Assert-MergeLayout $entry (Join-Path $InstallDir $entry.Name)
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
                try { Move-ForInstall $old $oldBin -Required -OldBin }
                catch { throw "Cannot move the old MoonBit bin directory. Close any processes using it and retry. $($_.Exception.Message)" }
                Merge-OldBin $oldBin $newBin $old.FullName
                Protect-OldImages (Get-Entry $oldBin) $liveBin
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
            Move-ForInstall (Get-Entry $newBin) $liveBin -Required -NewBin
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
            if ($move.OldBin -and $requiredRestoreFailed) { continue }
            try { Move-Entry $move.Destination $move.Source $move.Directory }
            catch {
                $restoreErrors.Add($_.Exception.Message)
                if ($move.Required) { $requiredRestoreFailed = $true }
                # If new bin is still live, keep its matching lib and include in place.
                if ($move.NewBin) { break }
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
