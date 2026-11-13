# Run from the extracted bootstrap ZIP. Requires Windows PowerShell 5.1 or later.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$lockPath = Join-Path $PSScriptRoot 'versions.lock.json'
$stage = $null
function Test-Sha([string]$Path, [string]$Sha) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Sha)
}
function Get-Asset($Asset, [string]$Kind, [string]$Path) {
    if ($Asset.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw "Invalid SHA-256 for $Kind." }
    $allowed = switch ($Kind) {
        'OptiScaler' { '^https://github\.com/[Oo]pti[Ss]caler/OptiScaler-nightly/releases/download/nightly-[0-9]{8}/OptiScaler_[A-Za-z0-9._-]+\.7z$' }
        'Mochizuki'  { '^https://gitlab\.com/(api/v4/projects/88319462/packages/generic/dlssnr-amd/[0-9.]+|mochizuki0323/DLSSNR-AMD/-/releases/v[0-9.]+/downloads)/DLSSNR-AMD-Vulkan-Windows-[0-9.]+-preview-x86_64\.zip$' }
        'CJK'        { '^https://gitlab\.com/(api/v4/projects/88319462/packages/generic/dlssnr-amd/[0-9.]+|mochizuki0323/DLSSNR-AMD/-/releases/v[0-9.]+/downloads)/DLSSNR-AMD-lang-CJK-[0-9.]+\.zip$' }
    }
    if ([string]$Asset.url -cnotmatch $allowed) { throw "Unexpected upstream URL for $Kind." }
    Write-Host "Downloading $Kind..."
    Invoke-WebRequest -UseBasicParsing -Uri $Asset.url -OutFile $Path -MaximumRedirection 6 -TimeoutSec 600
    if (-not (Test-Sha $Path $Asset.sha256)) { throw "SHA-256 mismatch for $Kind. Nothing will be installed." }
}
function Assert-OptiLayout([string]$Path) {
    foreach ($file in @('OptiScaler.dll','OptiScaler.ini','setup_windows.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $file) -PathType Leaf)) { throw "OptiScaler archive is missing $file." }
    }
    foreach ($dir in @('OptiScaler','Licenses')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $dir) -PathType Container)) { throw "OptiScaler archive is missing $dir/." }
    }
}
try {
    if (-not $env:LOCALAPPDATA) { throw 'This installer requires Windows.' }
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    if ($lock.schema_version -ne 1 -or $lock.release_tag -cnotmatch '^mochi-v[0-9]+\.[0-9]+\.[0-9]+_opti-[0-9]{8}$') {
        throw 'Invalid or unsupported versions.lock.json.'
    }
    $cache = Join-Path $env:LOCALAPPDATA 'OptiScaler-Mochizuki'
    $dest = Join-Path $cache $lock.release_tag
    $lockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
    $stamp = Join-Path $dest '.bootstrap-ready'
    if (Test-Path -LiteralPath $dest) {
        if ((-not (Test-Path -LiteralPath $stamp -PathType Leaf)) -or
            ((Get-Content -Raw -LiteralPath $stamp).Trim() -ine $lockHash)) {
            throw "Existing cache does not match this release. Rename the cache folder and try again: $dest"
        }
    } else {
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $stage = Join-Path $cache ('.stage-' + [guid]::NewGuid().ToString('N'))
        $merged = Join-Path $stage 'merged'
        $optArchive = Join-Path $stage 'OptiScaler.7z'
        $mochiArchive = Join-Path $stage 'Mochizuki.zip'
        New-Item -ItemType Directory -Force -Path $merged | Out-Null
        Get-Asset $lock.optiscaler 'OptiScaler' $optArchive
        Get-Asset $lock.mochizuki 'Mochizuki' $mochiArchive
        Expand-Archive -LiteralPath $mochiArchive -DestinationPath $merged
        foreach ($file in @('install.bat','install.ps1','optiscaler\asi\dlssnr-amd.asi','model-tools\dlssnr_extract_model.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $merged $file) -PathType Leaf)) { throw "Mochizuki archive is missing $file." }
        }
        $newOpt = Join-Path $stage 'opti'
        New-Item -ItemType Directory -Force -Path $newOpt | Out-Null
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        $extracted = $false
        if ($tar) {
            & $tar.Source -xf $optArchive -C $newOpt
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
            & $seven x $optArchive "-o$newOpt" -y
            if ($LASTEXITCODE -ne 0) { throw '7-Zip could not extract OptiScaler.' }
        }
        Assert-OptiLayout $newOpt
        $oldOpt = Join-Path $merged 'optiscaler\release'
        Remove-Item -LiteralPath $oldOpt -Recurse -Force
        Move-Item -LiteralPath $newOpt -Destination $oldOpt
        if ($null -ne $lock.cjk) {
            $cjkArchive = Join-Path $stage 'CJK.zip'
            Get-Asset $lock.cjk 'CJK' $cjkArchive
            Expand-Archive -LiteralPath $cjkArchive -DestinationPath (Join-Path $merged 'dlssnr-amd') -Force
        }
        Set-Content -LiteralPath (Join-Path $merged '.bootstrap-ready') -Value $lockHash -Encoding ASCII
        [IO.Directory]::Move($merged, $dest)
    }
    $installer = Join-Path $dest 'install.bat'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Cached installer is missing. Rename this folder and retry: $dest" }
    Write-Host 'Choose the actual game EXE, then choose 1) optiscaler.'
    Write-Host 'On first install, select your own compatible nvngx_dlssnr.dll when prompted.'
    Write-Host "Bundle cache: $dest"
    & $installer
} catch {
    Write-Host ("Setup failed: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
