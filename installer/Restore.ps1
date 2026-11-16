$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'OptionalProfiles.ps1')
    $game = (Read-Host 'Close the game. Folder containing OptiScaler.ini').Trim('"')
    $backup = (Read-Host 'Backup folder printed when the optional profile was applied').Trim('"')
    Restore-OptionalProfile $game $backup
} catch {
    Write-Host ("Restore failed: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
