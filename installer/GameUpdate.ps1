# In-place updates for this bundle's known layout. Dot-source OptionalProfiles.ps1 first.
# Copies verified payload files; never invokes the first-install script or loads a DLL.
function Test-UpdatePe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream=[IO.File]::OpenRead($Path)
    try {
        $reader=[IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 90 -or $reader.ReadUInt16() -ne 0x5a4d) { return $false }
        $stream.Position=60; $offset=$reader.ReadUInt32()
        if ($offset -gt $stream.Length-26) { return $false }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { return $false }
        $stream.Position=$offset+22
        return (($reader.ReadUInt16() -band 0x2000) -ne 0)
    } finally { $stream.Dispose() }
}
function Test-OptiProxy([string]$Path) {
    if (-not (Test-UpdatePe $Path)) { return $false }
    # Stock OptiScaler has no version resource. Read its PE export-directory image name,
    # without loading the DLL or executing any code.
    if ((Get-Item -LiteralPath $Path).Length -gt 64MB) { return $false }
    $bytes=[IO.File]::ReadAllBytes($Path)
    try {
        $pe=[BitConverter]::ToUInt32($bytes,60)
        $sections=[BitConverter]::ToUInt16($bytes,$pe+6)
        $optionalSize=[BitConverter]::ToUInt16($bytes,$pe+20)
        $optional=$pe+24
        if ($optionalSize -lt 120 -or [BitConverter]::ToUInt16($bytes,$optional) -ne 0x20b) { return $false }
        $exportRva=[BitConverter]::ToUInt32($bytes,$optional+112)
        $table=$optional+$optionalSize
        if ($sections -lt 1 -or $sections -gt 96 -or $table+40*$sections -gt $bytes.Length) { return $false }
        $ranges=@()
        for ($i=0; $i -lt $sections; $i++) {
            $base=$table+40*$i
            $ranges+=@{rva=[BitConverter]::ToUInt32($bytes,$base+12); size=[BitConverter]::ToUInt32($bytes,$base+16); offset=[BitConverter]::ToUInt32($bytes,$base+20)}
        }
        $exportOffset=$null
        foreach ($range in $ranges) {
            if ($exportRva -ge $range.rva -and [long]$exportRva+40 -le [long]$range.rva+$range.size) { $exportOffset=[long]$range.offset+$exportRva-$range.rva; break }
        }
        if ($null -eq $exportOffset -or $exportOffset+40 -gt $bytes.Length) { return $false }
        $nameRva=[BitConverter]::ToUInt32($bytes,$exportOffset+12); $nameOffset=$null
        foreach ($range in $ranges) {
            if ($nameRva -ge $range.rva -and [long]$nameRva+15 -le [long]$range.rva+$range.size) { $nameOffset=[long]$range.offset+$nameRva-$range.rva; break }
        }
        if ($null -eq $nameOffset -or $nameOffset+15 -gt $bytes.Length) { return $false }
        return [Text.Encoding]::ASCII.GetString($bytes,$nameOffset,15) -ieq "OptiScaler.dll`0"
    } catch { return $false }
}
function Get-UpdateHash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-GameUpdateTarget([string]$Game) {
    $Game=[IO.Path]::GetFullPath($Game).TrimEnd([char[]]'\/')
    Assert-ProfileStopped $Game
    $ini=Get-ProfilePath $Game 'OptiScaler.ini'
    foreach ($relative in @('OptiScaler.ini','dlssnr-amd.ini','OptiScaler/plugins/dlssnr-amd.asi')) {
        if (-not (Test-Path -LiteralPath (Get-ProfilePath $Game $relative) -PathType Leaf)) { throw "Not a recognized OptiScaler/Mochizuki bundle: missing $relative" }
    }
    if (-not (Test-Path -LiteralPath (Get-ProfilePath $Game 'dlssnr-amd') -PathType Container)) { throw 'Mochizuki runtime directory is missing.' }
    $settings=@([IO.File]::ReadAllLines($ini) | Where-Object { $_ -match '^\s*OptiDllPath\s*=' })
    if ($settings.Count -gt 1 -or ($settings.Count -eq 1 -and ($settings[0] -replace '^\s*OptiDllPath\s*=\s*','').Trim() -notin @('auto','OptiScaler','OptiScaler\','./OptiScaler','.\OptiScaler'))) { throw 'Custom OptiDllPath cannot be updated safely.' }
    $statePath=Get-ProfilePath $Game 'OptiScaler/.bundle-update-state.json'
    $state=$null; $proxy=$null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.schema_version -ne 1 -or $state.proxy -cnotmatch '^[A-Za-z0-9_.-]+\.dll$') { throw 'Unrecognized bundle update record.' }
        $candidate=Get-ProfilePath $Game $state.proxy
        $proxyRecord=@($state.files | Where-Object { $_.path -ieq $state.proxy })
        if ($proxyRecord.Count -ne 1 -or -not (Test-UpdatePe $candidate) -or (Get-UpdateHash $candidate) -ine $proxyRecord[0].sha256) { throw 'The recorded OptiScaler proxy has changed; refusing to overwrite another DLL.' }
        $proxy=$state.proxy
    } else {
        $legacy=Get-ProfilePath $Game 'dlssnr-amd-install.txt'
        if (-not (Test-Path -LiteralPath $legacy -PathType Leaf)) { throw 'No bundle installation record. A manual install must be identified before updating.' }
        $lines=@(Get-Content -LiteralPath $legacy | ForEach-Object { $_.TrimStart([char]0xfeff).Replace('\','/') })
        foreach ($required in @('F OptiScaler.ini','D OptiScaler','D dlssnr-amd')) {
            if ($lines -inotcontains $required) { throw "Installation record lacks $required; no files changed." }
        }
        $recognized=@(Get-ChildItem -LiteralPath $Game -Filter '*.dll' -File | Where-Object { Test-OptiProxy $_.FullName })
        if ($recognized.Count -ne 1) { throw 'Expected exactly one identifiable OptiScaler proxy. No DLL will be guessed or replaced.' }
        $proxy=$recognized[0].Name
        if ($lines -inotcontains ('F ' + $proxy)) { throw 'OptiScaler proxy is not in the original installation record; inspect this renamed/manual layout first.' }
    }
    # Reject a second OptiScaler proxy, even when a prior updater record names one.
    $extra=@(Get-ChildItem -LiteralPath $Game -Filter '*.dll' -File | Where-Object { $_.Name -ine $proxy -and (Test-OptiProxy $_.FullName) })
    if ($extra.Count) { throw 'Multiple OptiScaler proxies found; resolve the ambiguity first.' }
    foreach ($relative in @('OptiScaler','OptiScaler/plugins','dlssnr-amd')) { [void](Get-ProfilePath $Game $relative) }
    return @{game=$Game; proxy=$proxy; state=$state}
}
function Update-InstalledGameCore([string]$Game, [string]$Payload, $Lock) {
    $target=Assert-GameUpdateTarget $Game; $Game=$target.game
    if ($Lock.schema_version -ne 3 -or $Lock.release_tag -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$') { throw 'Invalid target lock.' }
    # Model ABI compatibility is explicitly reviewed, not inferred from a new release tag.
    if ($Lock.mochizuki.tag -cne 'v0.0.9') { throw 'This updater has verified model compatibility only for Mochizuki v0.0.9. A newer runtime requires a reviewed updater.' }
    $release=Get-ProfilePath $Payload 'optiscaler/release'
    $core=Get-ProfilePath $release 'OptiScaler.dll'
    if (-not (Test-OptiProxy $core)) { throw 'Target core is not an identifiable x64 OptiScaler DLL.' }
    $writes=@{}; $writes[$target.proxy]=$core
    $runtime=Get-ProfilePath $release 'OptiScaler'
    if (-not (Test-Path -LiteralPath $runtime -PathType Container)) { throw 'Prepared OptiScaler runtime is missing.' }
    foreach ($file in Get-ChildItem -LiteralPath $runtime -Recurse -File) {
        $relative=$file.FullName.Substring($runtime.Length+1).Replace('\','/')
        if ($relative -match '^(plugins|custom)/' -or $file.Extension -in @('.ini','.cfg','.json','.toml','.yaml','.yml','.bat','.cmd','.ps1','.sh','.bin','.onnx','.safetensors','.pt','.pth') -or $file.Name -like 'nvngx_dlss*.dll' -or $file.Name -eq '.bundle-update-state.json') { continue }
        # Runtime files stay beneath this bundle's owned directory; no top-level game DLL is guessed.
        $writes['OptiScaler/' + $relative]=$file.FullName
    }
    foreach ($name in @('MFGUnlocker','OptiPatcher')) {
        $relative="OptiScaler/plugins/$name.asi"
        $enabled=Test-Path -LiteralPath (Get-ProfilePath $Game $relative) -PathType Leaf
        $disabled=Test-Path -LiteralPath (Get-ProfilePath $Game ($relative + '.disabled-anr')) -PathType Leaf
        if ($enabled -and $disabled) { throw "Both enabled and ANR-disabled $name files exist; restore/resolve the profile before updating." }
        if ($enabled) {
            if (-not (Test-UpdatePe (Get-ProfilePath $Game $relative))) { throw "Existing $name plugin is not a valid x64 DLL; refusing to replace it." }
            $source=Get-ProfilePath $release $relative
            if (-not (Test-UpdatePe $source)) { throw "Prepared $name plugin is missing or invalid." }
            $writes[$relative]=$source
        }
        # Disabled files are deliberately NOT refreshed: optional-profile restore hashes refer to them.
    }
    $nrPlugin=Get-ProfilePath $Payload 'optiscaler/asi/dlssnr-amd.asi'
    if (-not (Test-UpdatePe $nrPlugin)) { throw 'Prepared Mochizuki plugin is invalid.' }
    $writes['OptiScaler/plugins/dlssnr-amd.asi']=$nrPlugin
    $nrRuntime=Get-ProfilePath $Payload 'dlssnr-amd'
    if (-not (Test-Path -LiteralPath $nrRuntime -PathType Container)) { throw 'Prepared Mochizuki runtime is missing.' }
    foreach ($file in Get-ChildItem -LiteralPath $nrRuntime -Recurse -File) {
        $relative=$file.FullName.Substring($nrRuntime.Length+1).Replace('\','/')
        # Never overwrite models, local presets/configuration, logs, caches, or user imports.
        if ($file.Extension -in @('.ini','.cfg','.bin','.onnx','.safetensors','.pt','.pth','.log','.dmp') -or $file.Name -ieq 'settings.txt' -or $relative -match '(^|/)(cache|models|presets|backup)(/|$)') { continue }
        $writes['dlssnr-amd/' + $relative]=$file.FullName
    }
    $probe=Get-ProfilePath $Payload 'optiscaler/asi/nr_present_probe.exe'
    if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw 'Prepared Mochizuki probe is missing.' }
    $writes['dlssnr-amd/nr_present_probe.exe']=$probe
    $licenses=Get-ProfilePath $release 'Licenses'
    if (Test-Path -LiteralPath $licenses -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $licenses -Recurse -File) {
            $relative=$file.FullName.Substring($licenses.Length+1).Replace('\','/')
            $writes['OptiScaler/Licenses/' + $relative]=$file.FullName
        }
    }
    # Preflight all sources and destinations, and refuse overwritten files edited since our last update.
    $previous=@{}
    if ($target.state) {
        foreach ($record in $target.state.files) {
            [void](Get-ProfilePath $Game $record.path)
            if ($previous.ContainsKey($record.path)) { throw 'Duplicate tracked path in update record.' }
            $previous[$record.path]=$record.sha256
        }
    }
    $tracked=@(); $changed=@{}
    foreach ($relative in $writes.Keys) {
        $destination=Get-ProfilePath $Game $relative; $source=$writes[$relative]
        [void](Get-ProfilePath $Payload ($source.Substring([IO.Path]::GetFullPath($Payload).TrimEnd([char[]]'\/').Length+1).Replace('\','/')))
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing prepared file: $relative" }
        if (Test-Path -LiteralPath $destination -PathType Container) { throw "File target is a directory: $relative" }
        $newHash=Get-UpdateHash $source
        $oldHash=if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-UpdateHash $destination } else { $null }
        if ($previous.ContainsKey($relative) -and $oldHash -ine $previous[$relative]) { throw "Managed file was modified after the previous update: $relative" }
        $tracked+=@{path=$relative; sha256=$newHash}
        if ($newHash -ine $oldHash) { $changed[$relative]=$source }
    }
    if ($changed.Count -eq 0 -and $target.state -and $target.state.release_tag -ceq $Lock.release_tag) { Write-Host 'Installed managed files already match this release. Configs and models were left untouched.'; return $null }
    $backup=Get-ProfilePath $Game ('.optiscaler-bundle-backups/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    $stateNew=Join-Path $backup 'new-update-state.json'
    @{schema_version=1; release_tag=$Lock.release_tag; proxy=$target.proxy; files=$tracked; optional_components='preserved-not-updated'; mochizuki_model_abi='v0.0.9'; updated_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $stateNew -Encoding UTF8
    $changed['OptiScaler/.bundle-update-state.json']=$stateNew
    $records=@()
    foreach ($relative in $changed.Keys) {
        $destination=Get-ProfilePath $Game $relative
        $exists=Test-Path -LiteralPath $destination -PathType Leaf
        $before=$null
        if ($exists) {
            $saved=Get-ProfilePath $backup ('files/' + $relative)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
            Copy-Item -LiteralPath $destination -Destination $saved
            $before=Get-UpdateHash $saved
        }
        $records+=@{path=$relative; existed=$exists; before=$before; after=(Get-UpdateHash $changed[$relative])}
    }
    @{game=$Game; profile='game-update'; files=$records; release_tag=$Lock.release_tag} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
    try {
        foreach ($relative in $changed.Keys) {
            $destination=Get-ProfilePath $Game $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $changed[$relative] -Destination $destination -Force
            if ((Get-UpdateHash $destination) -ine (Get-UpdateHash $changed[$relative])) { throw "Post-copy verification failed: $relative" }
        }
    } catch {
        $failure=$_
        Restore-OptionalProfile $Game $backup -Force
        throw $failure
    }
    Write-Host "Updated $($changed.Count-1) managed files in place; kept proxy $($target.proxy)."
    Write-Host 'Preserved INI settings, model weights and optional OpenRR/ANR payloads. Optional components were NOT refreshed.'
    Write-Host "Rollback with Restore.cmd. Backup: $backup"
    return $backup
}

function Test-GameBundleCurrent($Target, $Lock) {
    if (-not $Target -or -not $Target.state -or $Target.state.schema_version -ne 1 -or $Target.state.release_tag -cne $Lock.release_tag -or $Lock.schema_version -ne 3) { return $false }
    try {
        foreach ($record in $Target.state.files) {
            $path=Get-ProfilePath $Target.game $record.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-UpdateHash $path) -ine $record.sha256) { return $false }
        }
        return @($Target.state.files).Count -gt 0
    } catch { return $false }
}
function Update-InstalledGame([string]$Game, [string]$Payload, $Lock) {
    [void](Assert-GameUpdateTarget $Game)
    $lockPath=Get-ProfilePath $Game '.optiscaler-bundle-update.lock'
    $lease=$null
    try {
        try { $lease=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Another bundle update is running, or the game directory is not writable.' }
        if ($lease.Length -ne 0) { throw 'Reserved updater lock path contains data; refusing to alter it.' }
        return Update-InstalledGameCore $Game $Payload $Lock
    } finally {
        if ($lease) { $lease.Dispose() }
        # Keep the empty lock file: deleting it can race another process opening it.
    }
}
