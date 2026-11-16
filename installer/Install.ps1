# Run from the extracted bootstrap ZIP. Requires Windows PowerShell 5.1 or later.
param([switch]$Update, [string]$GamePath)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$lockPath = Join-Path $PSScriptRoot 'versions.lock.json'
$discoveryStage = $null
function Test-Sha([string]$Path, [string]$Sha) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Sha)
}
function Get-Asset($Asset, [string]$Kind, [string]$Path) {
    if ($Asset.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw "Invalid SHA-256 for $Kind." }
    $allowed = switch ($Kind) {
        'OptiScaler' { '^https://github\.com/[Oo]pti[Ss]caler/OptiScaler-nightly/releases/download/nightly-[0-9]{8}/OptiScaler_[A-Za-z0-9._-]+\.7z$' }
        'Mochizuki'  { '^https://gitlab\.com/(api/v4/projects/88319462/packages/generic/dlssnr-amd/[0-9.]+|mochizuki0323/DLSSNR-AMD/-/releases/v[0-9.]+/downloads)/DLSSNR-AMD-Vulkan-Windows-[0-9.]+-preview-x86_64\.zip$' }
        'MFGUnlocker' { '^https://github\.com/dashdogy/MFG-Unlocker/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/MFGUnlocker-v[0-9]+\.[0-9]+\.[0-9]+\.zip$' }
        'OptiPatcher' { '^https://github\.com/[Oo]ptiscaler/OptiPatcher/releases/download/(rolling|v[0-9]+\.[0-9]+(\.[0-9]+)?)/OptiPatcher(_v[0-9]+\.[0-9]+(\.[0-9]+)?[A-Za-z]?)?\.asi$' }
        'OpenRR'     { '^https://github\.com/TheAutomatic/dlss-5-amd-project/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/OptiScaler-NR-[0-9]+\.[0-9]+\.[0-9]+\.zip$' }
        'ANR'        { '^https://github\.com/apex-compute/ANR/releases/download/FG-V\.B[0-9]+/anr-fg-V\.B[0-9]+-addon\.zip$' }
        'CJK'        { '^https://gitlab\.com/(api/v4/projects/88319462/packages/generic/dlssnr-amd/[0-9.]+|mochizuki0323/DLSSNR-AMD/-/releases/v[0-9.]+/downloads)/DLSSNR-AMD-lang-CJK-[0-9.]+\.zip$' }
    }
    if (-not $allowed -or [string]$Asset.url -cnotmatch $allowed) { throw "Unexpected upstream URL for $Kind." }
    Write-Host "Downloading $Kind..."
    Invoke-WebRequest -UseBasicParsing -Uri $Asset.url -OutFile $Path -MaximumRedirection 6 -TimeoutSec 600
    if (-not (Test-Sha $Path $Asset.sha256)) { throw "SHA-256 mismatch for $Kind. Nothing will be installed." }
}
function Get-ReusableZip($Asset, [string]$Kind, [string]$Cache) {
    if ($Kind -notin @('Mochizuki','CJK') -or $Asset.sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Invalid reusable ZIP reference.'
    }
    $assetDir = Join-Path $Cache '.verified-downloads'
    $verified = Join-Path $assetDir ($Asset.sha256 + '.zip')
    if (Test-Sha $verified $Asset.sha256) { return $verified }
    New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
    $temp = Join-Path $assetDir ('.download-' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Get-Asset $Asset $Kind $temp
        # Do not overwrite an identical file another installer has just cached.
        if (-not (Test-Sha $verified $Asset.sha256)) {
            Move-Item -LiteralPath $temp -Destination $verified -Force
        }
        return $verified
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
function Assert-OptiLayout([string]$Path) {
    foreach ($file in @('OptiScaler.dll','OptiScaler.ini','setup_windows.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $file) -PathType Leaf)) { throw "OptiScaler archive is missing $file." }
    }
    foreach ($dir in @('OptiScaler','Licenses')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $dir) -PathType Container)) { throw "OptiScaler archive is missing $dir/." }
    }
}
function Enable-AsiPlugins([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path)
    $section = ''
    $count = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]') { $section = $Matches[1]; continue }
        if ($section -ieq 'Plugins' -and $lines[$i] -match '^\s*LoadAsiPlugins\s*=') {
            $lines[$i] = 'LoadAsiPlugins=true'
            $count++
        }
    }
    if ($count -ne 1) { throw 'Expected exactly one [Plugins] LoadAsiPlugins setting.' }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}
function Add-GraphicsPlugins($Lock, [string]$Stage, [string]$Opti) {
    if ($Lock.mfgunlocker.member -cne 'MFGUnlocker.dll' -or $null -ne $Lock.optipatcher.member) {
        throw 'Unexpected graphics plugin layout.'
    }
    $plugins = Join-Path $Opti 'OptiScaler\plugins'
    New-Item -ItemType Directory -Force -Path $plugins | Out-Null
    $mfgArchive = Join-Path $Stage 'MFGUnlocker.zip'
    $mfgContents = Join-Path $Stage 'MFGUnlocker'
    Get-Asset $Lock.mfgunlocker 'MFGUnlocker' $mfgArchive
    Expand-Archive -LiteralPath $mfgArchive -DestinationPath $mfgContents
    Copy-Item -LiteralPath (Join-Path $mfgContents $Lock.mfgunlocker.member) -Destination (Join-Path $plugins 'MFGUnlocker.asi') -Force
    Get-Asset $Lock.optipatcher 'OptiPatcher' (Join-Path $plugins 'OptiPatcher.asi')
    Enable-AsiPlugins (Join-Path $Opti 'OptiScaler.ini')
}
function Read-BundleLock([string]$LockFile) {
    $lock = Get-Content -Raw -LiteralPath $LockFile -Encoding UTF8 | ConvertFrom-Json
    if ($lock.schema_version -ne 3 -or $lock.installer_edition -ne 1 -or $lock.release_tag -cnotmatch '^bundle-[0-9]{8}-[a-f0-9]{20}$') {
        throw 'Invalid or unsupported versions.lock.json. Download a newer installer ZIP if necessary.'
    }
    return $lock
}
function Get-BundleCache($Lock, [string]$LockFile, [string]$Cache) {
    $dest = Join-Path $Cache $Lock.release_tag
    $lockHash = (Get-FileHash -LiteralPath $LockFile -Algorithm SHA256).Hash
    $stamp = Join-Path $dest '.bootstrap-ready'
    if (Test-Path -LiteralPath $dest) {
        if ((-not (Test-Path -LiteralPath $stamp -PathType Leaf)) -or
            ((Get-Content -Raw -LiteralPath $stamp).Trim() -ine $lockHash)) {
            throw "Existing cache does not match this release. Rename the cache folder and try again: $dest"
        }
        return $dest
    }
    $stage = $null
    try {
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $stage = Join-Path $cache ('.stage-' + [guid]::NewGuid().ToString('N'))
        $merged = Join-Path $stage 'merged'
        $optArchive = Join-Path $stage 'OptiScaler.7z'
        New-Item -ItemType Directory -Force -Path $merged | Out-Null
        Get-Asset $lock.optiscaler 'OptiScaler' $optArchive
        $mochiArchive = Get-ReusableZip $Lock.mochizuki 'Mochizuki' $Cache
        Expand-Archive -LiteralPath $mochiArchive -DestinationPath $merged
        foreach ($file in @('install.bat','install.ps1','optiscaler\asi\dlssnr-amd.asi','model-tools\dlssnr_extract_model.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $merged $file) -PathType Leaf)) { throw "Mochizuki archive is missing $file." }
        }
        $newOpt = Join-Path $stage 'opti'
        New-Item -ItemType Directory -Force -Path $newOpt | Out-Null
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        $extracted = $false
        if ($tar) {
            & $tar.Source -xf $optArchive -C $newOpt | Out-Host
            $extracted = $LASTEXITCODE -eq 0
        }
        if (-not $extracted) {
            $seven = @((Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
            $fromPath = Get-Command 7z.exe -ErrorAction SilentlyContinue
            if ($fromPath) { $seven += $fromPath.Source }
            $seven = $seven | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            if (-not $seven) { throw 'Windows tar could not open the .7z. Install official 7-Zip and retry.' }
            Remove-Item -LiteralPath $newOpt -Recurse -Force
            New-Item -ItemType Directory -Force -Path $newOpt | Out-Null
            & $seven x $optArchive "-o$newOpt" -y | Out-Host
            if ($LASTEXITCODE -ne 0) { throw '7-Zip could not extract OptiScaler.' }
        }
        Assert-OptiLayout $newOpt
        Add-GraphicsPlugins $lock $stage $newOpt
        $oldOpt = Join-Path $merged 'optiscaler\release'
        Remove-Item -LiteralPath $oldOpt -Recurse -Force
        Move-Item -LiteralPath $newOpt -Destination $oldOpt
        if ($null -ne $lock.cjk) {
            $cjkArchive = Get-ReusableZip $Lock.cjk 'CJK' $Cache
            Expand-Archive -LiteralPath $cjkArchive -DestinationPath (Join-Path $merged 'dlssnr-amd') -Force
        }
        Set-Content -LiteralPath (Join-Path $merged '.bootstrap-ready') -Value $lockHash -Encoding ASCII
        try { [IO.Directory]::Move($merged, $dest) }
        catch {
            # Parallel invocations may prepare the same bundle. Accept only the identical complete cache.
            if (-not (Test-Path -LiteralPath $stamp -PathType Leaf) -or
                (Get-Content -Raw -LiteralPath $stamp).Trim() -ine $lockHash) { throw }
        }
        return $dest
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if (-not $env:LOCALAPPDATA) { throw 'This installer requires Windows.' }
    $cache = Join-Path $env:LOCALAPPDATA 'OptiScaler-Mochizuki'
    if ($Update) {
        . (Join-Path $PSScriptRoot 'OptionalProfiles.ps1')
        . (Join-Path $PSScriptRoot 'GameUpdate.ps1')
        . (Join-Path $PSScriptRoot 'GamePicker.ps1')
        . (Join-Path $PSScriptRoot 'LatestBundle.ps1')
        $game = Select-UpdateGame $GamePath
        if (-not $game) { return }
        $initialTarget = Assert-GameUpdateTarget $game
        $discoveryStage = Join-Path ([IO.Path]::GetTempPath()) ('opti-bundle-latest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $discoveryStage | Out-Null
        $lockPath = Get-LatestBundleLock $discoveryStage
        $lock = Read-BundleLock $lockPath
        if ($lock.mochizuki.tag -cne 'v0.0.9') {
            throw 'A newer Mochizuki model format has not been verified. No files changed. Download a reviewed updater when available.'
        }
        Write-Host ("Latest bundle: {0} (OptiScaler {1}, Mochizuki {2})" -f $lock.release_tag, $lock.optiscaler.tag, $lock.mochizuki.tag)
        $dest = $null
        while ($game) {
            try {
                $target = if ($initialTarget) { $initialTarget } else { Assert-GameUpdateTarget $game }
                $initialTarget = $null
                Write-Host "Selected game folder: $game"
                if (Test-GameBundleCurrent $target $lock) {
                    Write-Host 'Already up to date. No files changed.'
                } else {
                    Write-Host 'Existing INIs, local models, and optional OpenRR/ANR profiles stay in place.'
                    if ((Read-Host 'Update this game in place? [y/N]') -in @('y','yes')) {
                        if (-not $dest) { $dest = Get-BundleCache $lock $lockPath $cache }
                        $backup = Update-InstalledGame $game $dest $lock
                    }
                }
            } catch {
                if ($GamePath) { throw }
                Write-Host ("Could not update this game: " + $_.Exception.Message) -ForegroundColor Red
            }
            if ($GamePath -or (Read-Host 'Select another game? [y/N]') -notin @('y','yes')) { break }
            $game = Select-UpdateGame
        }
        return
    }
    $lock = Read-BundleLock $lockPath
    $dest = Get-BundleCache $lock $lockPath $cache
    $installer = Join-Path $dest 'install.bat'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Cached installer is missing. Rename this folder and retry: $dest" }
    Write-Host 'Choose the actual game EXE, then choose 1) optiscaler.'
    Write-Host 'On first install, select your own compatible nvngx_dlssnr.dll when prompted.'
    Write-Host 'For NR, use Mochizuki and leave MFG Unlocker DLSS 5 off. Test in an offline game.'
    Write-Host "Bundle cache: $dest"
    & $installer
    if ($LASTEXITCODE -ne 0) { throw 'Base installer did not complete successfully; optional addons were not applied.' }
    Write-Host 'Optional profiles: 0) Keep current base setup (default), 1) OpenRR, 2) ANR FG, 3) OpenRR + ANR FG'
    Write-Host 'OpenRR requires RX 9000 (RDNA4) and your own nvngx_dlssd.dll 310.9.1.0. OptiFG host stays OFF.'
    Write-Host 'ANR requires game DLSS frame generation; this profile disables MFG Unlocker until restored. Compatibility is experimental.'
    $choice = Read-Host 'Choose 0, 1, 2, or 3 (Enter keeps current setup)'
    if ($choice -and $choice -ne '0') {
        $profile = switch ($choice) { '1' { 'openrr' } '2' { 'anr' } '3' { 'both' } default { throw 'Invalid selection; optional profile not applied.' } }
        . (Join-Path $PSScriptRoot 'OptionalProfiles.ps1')
        $game = (Read-Host 'Close the game. Enter its folder containing the installed OptiScaler.ini').Trim('"')
        Assert-ProfileStopped $game
        $rrModel = $null
        if ($profile -in @('openrr','both')) {
            if ((Read-Host 'Confirm this is an AMD RX 9000 / RDNA4 system (type YES)') -cne 'YES') { throw 'OpenRR hardware was not confirmed; nothing optional changed.' }
            $rrModel = (Read-Host 'Path to your own nvngx_dlssd.dll 310.9.1.0 (never uploaded)').Trim('"')
            Assert-RrModel $rrModel
        }
        $optionalStage = Join-Path $cache ('.optional-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $optionalStage | Out-Null
        try {
            if ($profile -in @('openrr','both')) {
                $archive = Join-Path $optionalStage 'OpenRR.zip'
                Get-Asset $lock.openrr 'OpenRR' $archive
                Expand-ProfileZip $archive (Join-Path $optionalStage 'openrr') 'openrr'
            }
            if ($profile -in @('anr','both')) {
                $archive = Join-Path $optionalStage 'ANR.zip'
                Get-Asset $lock.anr 'ANR' $archive
                Expand-ProfileZip $archive (Join-Path $optionalStage 'anr') 'anr'
            }
            $backup = Apply-OptionalProfile $game $optionalStage $profile $rrModel
            Write-Host 'To switch back, run Restore.cmd from this bootstrap folder and provide the game and backup paths printed above.'
            Write-Host 'Enable DLSS RR / DLSS frame generation in the game as appropriate; check rendering and frame presentation, not only counters.'
        } finally {
            Remove-Item -LiteralPath $optionalStage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Host ("Setup failed: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($discoveryStage -and (Test-Path -LiteralPath $discoveryStage -PathType Container)) {
        Remove-Item -LiteralPath $discoveryStage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
