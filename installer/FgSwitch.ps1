# Dot-source OptionalProfiles.ps1 and GameUpdate.ps1 first. Never loads addon code.
function Get-FgIniValue([string]$Text,[string]$Key,[string]$Section='FrameGen') {
    $inside=$false; $sections=0; $values=@()
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]') { $inside=$Matches[1] -ieq $Section; if ($inside) { $sections++ } }
        elseif ($inside -and $line -match ('^\s*'+[regex]::Escape($Key)+'\s*=\s*(.*?)\s*$')) { $values+=($Matches[1] -split '[;#]',2)[0].Trim() }
    }
    if ($sections -gt 1 -or $values.Count -gt 1) { throw "Ambiguous FrameGen setting: $Key" }
    if ($values.Count) { return $values[0] }
    return 'auto'
}
function Test-FgAnrProvider([string]$Root) {
    foreach ($relative in @('nvngx_dlssg.dll','nr_fg.ini','path_table.json','size_table.json','adapters/pack.nrx','kernels/pack.nrx','kernels-portable/pack.nrx')) {
        if (-not (Test-Path -LiteralPath (Get-ProfilePath $Root $relative) -PathType Leaf)) { return $false }
    }
    if (-not (Test-UpdatePe (Get-ProfilePath $Root 'nvngx_dlssg.dll'))) { return $false }
    foreach ($backend in @('coopmat','dp4a','packed','portable-linalg','portable','portable-xmx')) {
        foreach ($format in @('pq10','srgb8')) {
            if (-not (Test-Path -LiteralPath (Get-ProfilePath $Root ("programs/fg-lite-any-$backend-$format/pack.nrx")) -PathType Leaf)) { return $false }
        }
    }
    $programs=Get-ProfilePath $Root 'programs'
    if (-not (Test-Path -LiteralPath $programs -PathType Container)) { return $false }
    $packs=@(Get-ChildItem -LiteralPath $programs -Recurse -File | Where-Object { $_.Name -eq 'pack.nrx' })
    foreach ($p in $packs) { [void](Get-ProfilePath $Root $p.FullName.Substring($Root.TrimEnd([char[]]'\/').Length+1)) }
    return $packs.Count -gt 0
}
function Get-BundleFgStatus([string]$Game) {
    $target=Assert-GameUpdateTarget $Game; $Game=$target.game
    $enabled='OptiScaler/plugins/MFGUnlocker.asi'; $disabled=$enabled+'.disabled-anr'
    foreach ($other in @('MFGUnlocker.asi','MFGUnlocker.asi.disabled-anr','plugins/MFGUnlocker.asi','plugins/MFGUnlocker.asi.disabled-anr')) {
        if (Test-Path -LiteralPath (Get-ProfilePath $Game $other)) { throw 'MFG Unlocker is in an unsupported location; no files changed.' }
    }
    $on=Test-Path -LiteralPath (Get-ProfilePath $Game $enabled)
    $off=Test-Path -LiteralPath (Get-ProfilePath $Game $disabled)
    if ($on -and $off) { throw 'Both enabled and disabled MFG Unlocker exist; resolve the collision first.' }
    $mfg=if ($on) { $enabled } elseif ($off) { $disabled } else { $null }
    if ($mfg -and -not (Test-UpdatePe (Get-ProfilePath $Game $mfg))) { throw 'Existing MFG Unlocker is not an x64 DLL.' }
    $anr=Get-ProfilePath $Game 'OptiScaler/custom/Apex Neural Rendering FG/dlssg'
    $hasAnr=Test-FgAnrProvider $anr
    if ((Test-Path -LiteralPath $anr) -and -not $hasAnr -and @(Get-ChildItem -LiteralPath $anr -Recurse -File).Count -gt 0) { throw 'Existing ANR provider is incomplete; repair it before switching. It was not overwritten.' }
    $text=[IO.File]::ReadAllText((Get-ProfilePath $Game 'OptiScaler.ini'))
    $input=Get-FgIniValue $text 'FGInput'; $output=Get-FgIniValue $text 'FGOutput'
    $replacement=Get-FgIniValue $text 'FGNvngxReplacement'; $hudless=Get-FgIniValue $text 'DisableHudless'
    $mode='Custom'
    if (($input -eq 'nvngxfg' -or $output -in @('dlssg','flipmeter')) -and $replacement -eq 'Apex Neural Rendering FG' -and $hasAnr) { $mode='ANR' }
    if ($input -eq 'upscaler' -and $output -eq 'xefg' -and $on -and (Get-FgIniValue $text 'LoadAsiPlugins' 'Plugins') -eq 'true') { $mode='XeMFG' }
    return [pscustomobject]@{Game=$Game; Mode=$mode; HasAnr=$hasAnr; HasMfg=($on -or $off); MfgEnabled=$on; MfgPath=$mfg; AnrPath=$anr; Target=$target}
}
function Set-BundleFgMode([string]$Game,[ValidateSet('ANR','XeMFG')][string]$Mode,[string]$AnrPayload,[string]$MfgPayload) {
    return Invoke-BundleFgTransaction $Game $Mode $AnrPayload $MfgPayload
}
function Enable-ManagerCoexistingFg([string]$Game,[string]$AnrPayload,[string]$MfgPayload) {
    return Invoke-BundleFgTransaction $Game Preserve $AnrPayload $MfgPayload
}
function Invoke-BundleFgTransaction([string]$Game,[ValidateSet('ANR','XeMFG','Preserve')][string]$Mode,[string]$AnrPayload,[string]$MfgPayload) {
    $status=Get-BundleFgStatus $Game; $Game=$status.Game
    $lockPath=Get-ProfilePath $Game '.optiscaler-bundle-update.lock'
    $handle=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { if ($handle.Length -ne 0) { throw 'Reserved updater lock path contains data.' }; return Set-BundleFgModeCore $Game $Mode $AnrPayload $MfgPayload } finally { $handle.Dispose() }
}
function Set-BundleFgModeCore([string]$Game,[ValidateSet('ANR','XeMFG','Preserve')][string]$Mode,[string]$AnrPayload,[string]$MfgPayload) {
    $status=Get-BundleFgStatus $Game
    $enabled='OptiScaler/plugins/MFGUnlocker.asi'; $disabled=$enabled+'.disabled-anr'
    $writes=@{}; $deletes=@(); $text=[IO.File]::ReadAllText((Get-ProfilePath $Game 'OptiScaler.ini'))
    $values=@{FGInput='nvngxfg'; FGOutput='nofg'; FGNvngxReplacement='Apex Neural Rendering FG'; DisableHudless='false'}
    if ($Mode -eq 'XeMFG' -and (Get-FgIniValue $text 'LoadAsiPlugins' 'Plugins') -ne 'true') { throw 'XeMFG requires [Plugins] LoadAsiPlugins=true. Enable it before switching.' }
    if ($Mode -eq 'XeMFG') { $values.FGInput='upscaler'; $values.FGOutput='xefg'; $values.FGNvngxReplacement='None' }
    if ($Mode -ne 'Preserve') { foreach ($key in $values.Keys) { $text=Set-ProfileIni $text 'FrameGen' $key $values[$key] } }
    if ($Mode -in @('ANR','Preserve') -and -not $status.HasAnr) {
        if (-not $AnrPayload) { throw 'ANR is not installed. Supply the verified extracted ANR addon payload.' }
        $provider=Get-ProfilePath ([IO.Path]::GetFullPath($AnrPayload)) 'dlssg'
        if (-not (Test-FgAnrProvider $provider)) { throw 'Prepared ANR provider is incomplete or invalid.' }
        foreach ($file in (Get-ChildItem -LiteralPath $provider -Recurse -File)) {
            $relative=$file.FullName.Substring($provider.Length+1).Replace('\','/')
            [void](Get-ProfilePath $provider $relative)
            if ($relative -cnotmatch '^(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(?:dll|ini|json|nrx)$') { throw 'Unexpected ANR payload member.' }
            $dest='OptiScaler/custom/Apex Neural Rendering FG/dlssg/'+$relative
            if (Test-Path -LiteralPath (Get-ProfilePath $Game $dest)) { throw 'ANR destination collision.' }
            $writes[$dest]=$file.FullName
        }
    }
    # Keep all providers installed. INI/menu selection, not deleting a plugin, chooses FG.
    $desired=$enabled
    if ($status.HasMfg -and $status.MfgPath -ne $desired) {
        $writes[$desired]=Get-ProfilePath $Game $status.MfgPath; $deletes+= $status.MfgPath
    } elseif (($Mode -in @('XeMFG','Preserve') -or $MfgPayload) -and -not $status.HasMfg) {
        if (-not $MfgPayload -or -not (Test-UpdatePe $MfgPayload)) { throw 'Installing MFG Unlocker needs a verified MFGUnlocker.asi payload.' }
        $writes[$enabled]=[IO.Path]::GetFullPath($MfgPayload)
    }
    # Track the same MFG bytes under their new path so the in-place updater remains valid.
    $state=$status.Target.state; $stateChanged=$false
    if ($state) {
        $seen=@{}; $trackedMfg=$false
        foreach ($record in $state.files) {
            [void](Get-ProfilePath $Game $record.path)
            if ($seen.ContainsKey($record.path)) { throw 'Duplicate updater record.' }; $seen[$record.path]=$true
            if ($record.path -in @($enabled,$disabled)) {
                if ($trackedMfg) { throw 'Duplicate logical MFG entry in updater record.' }
                $trackedMfg=$true
                if (-not $status.HasMfg -or (Get-UpdateHash (Get-ProfilePath $Game $status.MfgPath)) -ine $record.sha256) { throw 'MFG Unlocker differs from its update record; no files changed.' }
                if ($record.path -ne $desired) { $record.path=$desired; $stateChanged=$true }
            }
        }
        if (($status.HasMfg -or $writes.ContainsKey($enabled)) -and -not $trackedMfg) {
            # The updater may have skipped this disabled file. Force its next version check.
            $state.release_tag=''; $stateChanged=$true
            $source=if ($writes.ContainsKey($enabled)) { $writes[$enabled] } else { Get-ProfilePath $Game $enabled }
            $state.files=@($state.files)+@([pscustomobject]@{path=$enabled;sha256=(Get-UpdateHash $source)})
        }
    }
    $iniPath=Get-ProfilePath $Game 'OptiScaler.ini'
    if (($Mode -eq 'Preserve' -or $status.Mode -eq $Mode) -and $writes.Count -eq 0 -and -not $stateChanged) { if ($Mode -eq 'Preserve') { Write-Host 'ANR and MFG Unlocker are already installed together. No files changed.' } else { Write-Host "Already configured for $Mode. No files changed." }; return $null }
    $backup=Get-ProfilePath $Game ('.optiscaler-bundle-backups/'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if ($Mode -ne 'Preserve') {
        $newIni=Join-Path $backup 'new-OptiScaler.ini'; [IO.File]::WriteAllText($newIni,$text,[Text.UTF8Encoding]::new($false)); $writes['OptiScaler.ini']=$newIni
    }
    if ($stateChanged) {
        $newState=Join-Path $backup 'new-update-state.json'
        $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $newState -Encoding UTF8
        $writes['OptiScaler/.bundle-update-state.json']=$newState
    }
    $records=@()
    foreach ($relative in @(@($writes.Keys)+$deletes | Sort-Object -Unique)) {
        $path=Get-ProfilePath $Game $relative
        if (Test-Path -LiteralPath $path -PathType Container) { throw 'Destination is a directory.' }
        $exists=Test-Path -LiteralPath $path -PathType Leaf
        $before=if ($exists) { Get-UpdateHash $path } else { $null }
        if ($exists) { $save=Get-ProfilePath $backup ('files/'+$relative); New-Item -ItemType Directory -Path (Split-Path -Parent $save) -Force | Out-Null; Copy-Item -LiteralPath $path -Destination $save }
        $after=if ($writes.ContainsKey($relative)) { Get-UpdateHash $writes[$relative] } else { $null }
        $records+=@{path=$relative; existed=$exists; before=$before; after=$after}
    }
    @{game=$Game;profile='fg-switch';mode=$Mode;files=$records} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
    try {
        foreach ($relative in $writes.Keys) {
            $path=Get-ProfilePath $Game $relative; New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Copy-Item -LiteralPath $writes[$relative] -Destination $path -Force
        }
        foreach ($relative in $deletes) { Remove-Item -LiteralPath (Get-ProfilePath $Game $relative) -Force }
        foreach ($record in $records) {
            $path=Get-ProfilePath $Game $record.path
            $actual=if (Test-Path -LiteralPath $path -PathType Leaf) { Get-UpdateHash $path } else { $null }
            if ($actual -ine $record.after) { throw 'FG switch verification failed.' }
        }
        if ($Mode -ne 'Preserve' -and (Get-BundleFgStatus $Game).Mode -ne $Mode) { throw 'Resulting FG configuration was not recognized.' }
    } catch {
        $failure=$_; Restore-OptionalProfile $Game $backup -Force; throw $failure
    }
    if ($Mode -eq 'Preserve') { Write-Host 'ANR and MFG Unlocker are installed together. Current FrameGen selection and all tuning were preserved.' }
    else { Write-Host "Selected $Mode. MFG Unlocker remains installed; its standalone FG/NR settings were not enabled or changed." }
    Write-Host "Snapshot: $backup. Earlier Restore snapshots may refuse after this switch; use this switcher to change FG modes."
    return $backup
}
