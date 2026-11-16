# Local configuration/copy helpers only. Never executes an addon DLL or installer.
function Set-ProfileIni([string]$Text, [string]$Section, [string]$Key, [string]$Value) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Text -split '\r?\n'))
    $sectionCount = 0; $keyCount = 0; $inside = $false; $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]') {
            if ($inside) { $end = $i }
            $inside = $Matches[1] -ieq $Section
            if ($inside) { $sectionCount++ }
        } elseif ($inside -and $lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $keyCount++; $lines[$i] = "$Key=$Value"
        }
    }
    if ($sectionCount -gt 1 -or $keyCount -gt 1) { throw "Ambiguous INI setting: [$Section] $Key" }
    if ($sectionCount -eq 0) { $lines.Add("[$Section]"); $lines.Add("$Key=$Value") }
    elseif ($keyCount -eq 0) { $lines.Insert($end, "$Key=$Value") }
    return $lines -join "`r`n"
}
function Get-ProfilePath([string]$Root, [string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or
        ($Relative -split '[\\/]' | Where-Object { $_ -in @('..', '.', '') })) { throw 'Unsafe relative path.' }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    $path = [IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    if (-not $path.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes root.' }
    # Do not follow junctions/symlinks into another directory.
    $current = $path
    while ($current -and $current.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not allowed: $current" }
        }
        $current = Split-Path -Parent $current
    }
    return $path
}
function Assert-ProfileStopped([string]$Game) {
    $root = [IO.Path]::GetFullPath($Game).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count) { throw 'Close the game and its launcher before changing the optional profile.' }
}
function Assert-RrModel([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Select your own nvngx_dlssd.dll 310.9.1.0.' }
    if ([IO.Path]::GetFileName($Path) -ine 'nvngx_dlssd.dll') { throw 'Expected nvngx_dlssd.dll (not nvngx_dlssnr.dll).' }
    $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($v.FileMajorPart -ne 310 -or $v.FileMinorPart -ne 9 -or $v.FileBuildPart -ne 1 -or $v.FilePrivatePart -ne 0) {
        throw 'OpenRR requires nvngx_dlssd.dll exactly 310.9.1.0; no files were changed.'
    }
}
function Expand-ProfileZip([string]$Archive, [string]$Destination, [ValidateSet('openrr','anr')][string]$Kind) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen = @{}; [long]$total = 0; $selected = @{}
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\','/').TrimEnd('/')
            if (-not $name) { continue }
            $target = Get-ProfilePath $Destination $name
            if ($seen.ContainsKey($name.ToLowerInvariant())) { throw 'Duplicate ZIP member.' }
            $seen[$name.ToLowerInvariant()] = $true
            $mode = ($entry.ExternalAttributes -shr 16) -band 61440
            if ($mode -notin @(0, 32768, 16384)) { throw 'ZIP contains a non-regular member.' }
            $total += $entry.Length
            if ($total -gt 4GB) { throw 'Expanded ZIP exceeds limit.' }
            if (-not $entry.Name -or $entry.FullName.EndsWith('\')) { continue }
            $relative = $null
            if ($Kind -eq 'openrr') {
                if ($name -ceq 'OptiScaler/plugins/openrr-amd.asi') { $relative = 'openrr-amd.asi' }
                elseif ($name -ceq 'openrr-amd.ini' -or $name -cmatch '^openrr-amd/shaders/[A-Za-z0-9_.-]+\.spv$' -or $name -cin @('Licenses/OpenRR_MIT.txt','Licenses/OpenRR_THIRD_PARTY.md')) { $relative = $name }
            } elseif ($name -cmatch '^Apex Neural Rendering FG/dlssg/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(?:dll|ini|json|nrx)$') {
                $relative = $name
            }
            if ($relative) { $selected[$relative] = $entry }
        }
        foreach ($relative in $selected.Keys) {
            $target = Get-ProfilePath $Destination $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($selected[$relative], $target, $false)
        }
    } finally { $zip.Dispose() }
}
function Restore-OptionalProfile([string]$Game, [string]$Backup, [switch]$Force) {
    Assert-ProfileStopped $Game
    $root = Get-ProfilePath $Game '.optiscaler-bundle-backups'
    $backupFull = [IO.Path]::GetFullPath($Backup)
    if (-not $backupFull.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup must be inside this game backup directory.' }
    $manifest = Get-Content -LiteralPath (Join-Path $backupFull 'manifest.json') -Raw | ConvertFrom-Json
    if ([IO.Path]::GetFullPath($Game) -ine $manifest.game) { throw 'Backup belongs to a different game.' }
    # Preflight every file before restoring anything. Refuse to overwrite later user edits.
    foreach ($item in $manifest.files) {
        $target = Get-ProfilePath $Game $item.path
        if (-not $Force) {
            $actual = if (Test-Path -LiteralPath $target -PathType Leaf) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash } else { $null }
            if ($actual -ine $item.after) { throw "File changed since profile application: $($item.path). Restore manually from $Backup" }
        }
    }
    foreach ($item in $manifest.files) {
        $target = Get-ProfilePath $Game $item.path
        if ($item.existed) {
            $source = Get-ProfilePath $backupFull ('files/' + $item.path)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $item.before) { throw 'Backup integrity check failed.' }
        }
    }
    foreach ($item in $manifest.files) {
        $target = Get-ProfilePath $Game $item.path
        if ($item.existed) { Copy-Item -LiteralPath (Get-ProfilePath $backupFull ('files/' + $item.path)) -Destination $target -Force }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    }
    Write-Host "Optional profile restored. Backup retained: $Backup"
}
function Apply-OptionalProfile([string]$Game, [string]$Payload, [ValidateSet('openrr','anr','both')][string]$Profile, [string]$RrModel, [switch]$StageOpenRR) {
    if ($StageOpenRR -and $Profile -ne 'openrr') { throw 'StageOpenRR is only valid for the openrr profile.' }
    $Game = [IO.Path]::GetFullPath($Game)
    Assert-ProfileStopped $Game
    $ini = Get-ProfilePath $Game 'OptiScaler.ini'
    if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { throw 'Choose the game folder containing OptiScaler.ini after base installation.' }
    $text = [IO.File]::ReadAllText($ini)
    # This bundle installs to OptiScaler/. Fail closed for an externally customized DLL path.
    $pathLines = @($text -split '\r?\n' | Where-Object { $_ -match '^\s*OptiDllPath\s*=' })
    if ($pathLines.Count -gt 1 -or ($pathLines.Count -eq 1 -and ($pathLines[0] -replace '^\s*OptiDllPath\s*=\s*','').Trim() -notin @('auto','OptiScaler','OptiScaler\','./OptiScaler','.\OptiScaler'))) { throw 'Custom OptiDllPath is unsupported; optional profile was not applied.' }
    if (-not (Test-Path -LiteralPath (Get-ProfilePath $Game 'OptiScaler') -PathType Container)) { throw 'Expected the base bundle OptiScaler/ directory.' }
    $writes = @{}; $deletes = @()
    if ($Profile -in @('openrr','both')) {
        if (-not $StageOpenRR) { Assert-RrModel $RrModel }
        $source = Get-ProfilePath $Payload 'openrr'
        foreach ($relative in @('openrr-amd.asi','openrr-amd.ini')) {
            if (-not (Test-Path -LiteralPath (Get-ProfilePath $source $relative) -PathType Leaf)) { throw 'Incomplete OpenRR payload.' }
        }
        $shaders = @(Get-ChildItem -LiteralPath (Get-ProfilePath $source 'openrr-amd/shaders') -File -Filter '*.spv')
        if ($shaders.Count -lt 1) { throw 'OpenRR shaders are missing.' }
        foreach ($license in @('OpenRR_MIT.txt','OpenRR_THIRD_PARTY.md')) {
            $writes['Licenses/' + $license] = Get-ProfilePath $source ('Licenses/' + $license)
        }
        $activeRelative = 'OptiScaler/plugins/openrr-amd.asi'
        $disabledRelative = $activeRelative + '.disabled-rr'
        $active = Get-ProfilePath $Game $activeRelative
        $disabled = Get-ProfilePath $Game $disabledRelative
        if ((Test-Path -LiteralPath $active) -and (Test-Path -LiteralPath $disabled)) { throw 'OpenRR active and staged files both exist; resolve the collision before continuing.' }
        if ($StageOpenRR) {
            if (Test-Path -LiteralPath $active) { throw 'OpenRR is already active; staging must not disable an existing installation.' }
            $writes[$disabledRelative] = Get-ProfilePath $source 'openrr-amd.asi'
        } else {
            if (Test-Path -LiteralPath $disabled) {
                if ((Get-FileHash -LiteralPath $disabled -Algorithm SHA256).Hash -ine
                    (Get-FileHash -LiteralPath (Get-ProfilePath $source 'openrr-amd.asi') -Algorithm SHA256).Hash) { throw 'Staged OpenRR differs from the verified payload. Restage before enabling.' }
                $deletes += $disabledRelative
            }
            $writes[$activeRelative] = Get-ProfilePath $source 'openrr-amd.asi'
            $writes['openrr-amd/nvngx_dlssd.dll'] = [IO.Path]::GetFullPath($RrModel)
        }
        foreach ($shader in $shaders) { $writes['openrr-amd/shaders/' + $shader.Name] = $shader.FullName }
        $rrIni = Get-ProfilePath $Game 'openrr-amd.ini'
        # Existing tuning is owned by the user. Only a new config gets the safe host default.
        $writeRrIni = -not (Test-Path -LiteralPath $rrIni)
        if ($writeRrIni) {
            $rrText = [IO.File]::ReadAllText((Get-ProfilePath $source 'openrr-amd.ini'))
            $rrText = Set-ProfileIni $rrText 'OpenRR' 'OptiFGHost' 'false'
        }
        if (-not $StageOpenRR) {
            if (-not $writeRrIni) {
                $existingRrText = [IO.File]::ReadAllText($rrIni)
                if ($existingRrText -match '(?im)^\s*OptiFGHost\s*=\s*(true|1|yes|on)\b') { throw 'Existing OpenRR config enables OptiFGHost. Disable the experimental host explicitly before enabling this profile; tuning was not changed.' }
            }
            $text = Set-ProfileIni $text 'Plugins' 'LoadAsiPlugins' 'true'
        }
    }
    if ($Profile -in @('anr','both')) {
        $source = Get-ProfilePath $Payload 'anr/Apex Neural Rendering FG'
        if (-not (Test-Path -LiteralPath (Get-ProfilePath $source 'dlssg/nvngx_dlssg.dll') -PathType Leaf)) { throw 'ANR custom provider is missing.' }
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            $relative = $file.FullName.Substring($source.Length + 1).Replace('\','/')
            $target = 'OptiScaler/custom/Apex Neural Rendering FG/' + $relative
            # Keep the user's existing ANR tuning.
            if ($relative -eq 'dlssg/nr_fg.ini' -and (Test-Path -LiteralPath (Get-ProfilePath $Game $target))) { continue }
            $writes[$target] = $file.FullName
        }
        # MFG Unlocker stays installed; OptiScaler selects the FG backend.
        $text = Set-ProfileIni $text 'FrameGen' 'FGInput' 'nvngxfg'
        $text = Set-ProfileIni $text 'FrameGen' 'FGOutput' 'nofg'
        $text = Set-ProfileIni $text 'FrameGen' 'FGNvngxReplacement' 'Apex Neural Rendering FG'
        $text = Set-ProfileIni $text 'FrameGen' 'DisableHudless' 'false'
    }
    # Preflight all copy sources and targets before creating a transaction.
    foreach ($relative in @($writes.Keys) + $deletes) {
        $target = Get-ProfilePath $Game $relative
        if (Test-Path -LiteralPath $target -PathType Container) { throw "Target is a directory, not a file: $relative" }
        if ($writes.ContainsKey($relative)) {
            $copySource = $writes[$relative]
            if (-not (Test-Path -LiteralPath $copySource -PathType Leaf)) { throw "Payload file is missing: $relative" }
            if ((Get-Item -LiteralPath $copySource -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload source cannot be a reparse point.' }
        }
    }
    # Snapshot every target before any modification; local NVIDIA model never leaves this machine.
    $backup = Get-ProfilePath $Game ('.optiscaler-bundle-backups/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $generated = Join-Path $backup 'generated'
    New-Item -ItemType Directory -Path $generated | Out-Null
    if (-not $StageOpenRR) {
        [IO.File]::WriteAllText((Join-Path $generated 'OptiScaler.ini'), $text, [Text.UTF8Encoding]::new($false))
        $writes['OptiScaler.ini'] = Join-Path $generated 'OptiScaler.ini'
    }
    if ($Profile -in @('openrr','both') -and $writeRrIni) {
        [IO.File]::WriteAllText((Join-Path $generated 'openrr-amd.ini'), $rrText, [Text.UTF8Encoding]::new($false))
        $writes['openrr-amd.ini'] = Join-Path $generated 'openrr-amd.ini'
    }
    $records = @()
    foreach ($relative in @($writes.Keys) + $deletes) {
        $target = Get-ProfilePath $Game $relative
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        $before = $null
        if ($existed) {
            $saved = Get-ProfilePath $backup ('files/' + $relative)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
            Copy-Item -LiteralPath $target -Destination $saved
            $before = (Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash
        }
        $after = if ($writes.ContainsKey($relative)) { (Get-FileHash -LiteralPath $writes[$relative] -Algorithm SHA256).Hash } else { $null }
        $records += @{path=$relative; existed=$existed; before=$before; after=$after}
    }
    @{game=$Game; profile=$Profile; files=$records} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
    try {
        foreach ($relative in $writes.Keys) {
            $target = Get-ProfilePath $Game $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $writes[$relative] -Destination $target -Force
        }
        foreach ($relative in $deletes) { Remove-Item -LiteralPath (Get-ProfilePath $Game $relative) -Force }
    } catch {
        Restore-OptionalProfile $Game $backup -Force
        throw
    }
    Write-Host "Optional $Profile profile applied. This is not a game-compatibility test."
    Write-Host "Backup: $backup"
    return $backup
}
