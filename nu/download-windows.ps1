param(
    [string]$LockPath,
    [string]$Nu,
    [string]$Downloader,
    [string]$Url,
    [string]$Archive,
    [string]$CacheKey
)

$ErrorActionPreference = 'Stop'
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while ($true) {
    try {
        # Inherit the exclusive handle so the writer keeps the lock if this shell is killed.
        $lock = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'Inheritable')
        break
    }
    catch [IO.IOException] {
        # Only retry sharing or lock violations.
        $code = $_.Exception.GetBaseException().HResult -band 0xffff
        if ($code -notin 32, 33 -or [DateTime]::UtcNow -ge $deadline) { throw }
        Start-Sleep -Milliseconds 100
    }
}

try {
    & $Nu --no-config-file $Downloader $Url $Archive $CacheKey --locked
    exit $LASTEXITCODE
}
finally { $lock.Dispose() }
