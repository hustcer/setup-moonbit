$downloadItems = @(
    @{
        Url = "https://cli.moonbitlang.com/windows/moon.exe"
        TargetPath = "$env:USERPROFILE\.moon\moon.exe"
    },
    @{
        Url = "https://cli.moonbitlang.com/windows/moonc.exe"
        TargetPath = "$env:USERPROFILE\.moon\moonc.exe"
    },
    @{
        Url = "https://cli.moonbitlang.com/windows/moonfmt.exe"
        TargetPath = "$env:USERPROFILE\.moon\moonfmt.exe"
    },
    @{
        Url = "https://cli.moonbitlang.com/windows/moonrun.exe"
        TargetPath = "$env:USERPROFILE\.moon\moonrun.exe"
    }
)

$moonDir = "$env:USERPROFILE\.moon"

if (-not (Test-Path -Path $moonDir -PathType Container)) {
    Write-Host "Creating ~/.moon directory"
    New-Item -Path $moonDir -ItemType Directory
}

foreach ($item in $downloadItems) {
    $url = $item.Url
    $targetPath = $item.TargetPath

    Write-Host "Downloading $url to $targetPath"
    Invoke-WebRequest -Uri $url -OutFile $targetPath
}

$envPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)

$paths = $envPath -split ';'

$exists = $paths -contains $moonDir

if ($exists) {
    Write-Host "~/.moon is already in the PATH. Skipping"
} else {
    $envPath += ";$moonDir"
    [System.Environment]::SetEnvironmentVariable("PATH", $envPath, [System.EnvironmentVariableTarget]::User)
    Write-Host "Added ~/.moon to the PATH."
    Write-Host "You may need to restart your shell for the changes to take effect."
}
