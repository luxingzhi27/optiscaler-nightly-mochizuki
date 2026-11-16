param([string]$GamePath, [ValidateSet('ANR','XeMFG')][string]$Mode)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Get-VerifiedFgArchive($Asset, [ValidateSet('ANR','MFG')][string]$Kind, [string]$Path) {
    $patterns = @{
        ANR = '^https://github\.com/apex-compute/ANR/releases/download/FG-V\.B[0-9]+/anr-fg-V\.B[0-9]+-addon\.zip$'
        MFG = '^https://github\.com/dashdogy/MFG-Unlocker/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/MFGUnlocker-v[0-9]+\.[0-9]+\.[0-9]+\.zip$'
    }
    if ([string]$Asset.url -cnotmatch $patterns[$Kind] -or [string]$Asset.sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw "Unexpected official $Kind asset."
    }
    Write-Host "Preparing $Kind from the verified latest bundle..."
    [byte[]]$bytes = Get-BundleBytes $Asset.url 33554432 $true
    if ((Get-BundleDigest $bytes) -cne $Asset.sha256) { throw "SHA-256 mismatch for $Kind." }
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function Expand-MfgSwitchPayload([string]$ZipPath, [string]$AsiPath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $members = @($zip.Entries | Where-Object { $_.FullName -ieq 'MFGUnlocker.dll' })
        if ($members.Count -ne 1 -or $members[0].FullName -cne 'MFGUnlocker.dll' -or
            $members[0].Length -lt 1 -or $members[0].Length -gt 33554432 -or
            (($members[0].ExternalAttributes -shr 16) -band 61440) -notin @(0,32768)) {
            throw 'Unexpected MFG Unlocker ZIP layout.'
        }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($members[0], $AsiPath, $false)
    } finally { $zip.Dispose() }
}
$stage = $null
try {
    . (Join-Path $PSScriptRoot 'OptionalProfiles.ps1')
    . (Join-Path $PSScriptRoot 'GameUpdate.ps1')
    . (Join-Path $PSScriptRoot 'GamePicker.ps1')
    . (Join-Path $PSScriptRoot 'LatestBundle.ps1')
    . (Join-Path $PSScriptRoot 'FgSwitch.ps1')
    $game = Select-UpdateGame $GamePath
    if (-not $game) { return }
    $status = Get-BundleFgStatus $game
    Write-Host "Game folder: $game"
    Write-Host "Current frame generation profile: $($status.Mode)"
    if (-not $Mode) {
        Write-Host '1) ANR FG (game DLSS frame generation input)'
        Write-Host '2) XeMFG (official OptiScaler, DX12 upscaler input)'
        $choice = Read-Host 'Choose 1 or 2 (Enter cancels)'
        if (-not $choice) { return }
        $Mode = switch ($choice) { '1' {'ANR'} '2' {'XeMFG'} default {throw 'Choose 1 or 2.'} }
    }
    $anrPayload=$null; $mfgPayload=$null
    if (($Mode -eq 'ANR' -and -not $status.HasAnr) -or ($Mode -eq 'XeMFG' -and -not $status.HasMfg)) {
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('opti-switch-fg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
        $lock = Get-Content -Raw -LiteralPath (Get-LatestBundleLock $stage) -Encoding UTF8 | ConvertFrom-Json
        if ($Mode -eq 'ANR') {
            $archive = Join-Path $stage 'anr.zip'
            Get-VerifiedFgArchive $lock.anr 'ANR' $archive
            $extract = Join-Path $stage 'anr'
            Expand-ProfileZip $archive $extract 'anr'
            $anrPayload = Join-Path $extract 'Apex Neural Rendering FG'
        } else {
            $archive = Join-Path $stage 'mfg.zip'
            Get-VerifiedFgArchive $lock.mfgunlocker 'MFG' $archive
            $mfgPayload = Join-Path $stage 'MFGUnlocker.asi'
            Expand-MfgSwitchPayload $archive $mfgPayload
        }
    }
    $null = Set-BundleFgMode $game $Mode $anrPayload $mfgPayload
    if ($Mode -eq 'ANR') { Write-Host 'Reopen the game and enable its NVIDIA/DLSS frame generation option.' }
    else { Write-Host 'Reopen the game in DX12. Enable a supported upscaler and OptiScaler Frame Gen; choose the frame count in its menu.' }
} catch {
    Write-Host ("Could not switch frame generation: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
