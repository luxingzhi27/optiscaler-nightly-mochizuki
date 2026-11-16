# Local backend for the Windows manager. Loading this file never starts an installer.
$ErrorActionPreference='Stop'
$script:ManagerInstallerDir=Join-Path $PSScriptRoot 'installer'
if (-not (Test-Path -LiteralPath $script:ManagerInstallerDir -PathType Container)) { $script:ManagerInstallerDir=Join-Path (Split-Path -Parent $PSScriptRoot) 'installer' }
foreach ($helper in @('OptionalProfiles.ps1','GameUpdate.ps1','LatestBundle.ps1','FgSwitch.ps1')) { . (Join-Path $script:ManagerInstallerDir $helper) }
# Import only these local, shipped function definitions, not either CLI's interactive body.
foreach ($entry in @(
    @{File='Install.ps1';Names=@('Test-Sha','Get-Asset','Get-ReusableZip','Assert-OptiLayout','Enable-AsiPlugins','Add-GraphicsPlugins','Read-BundleLock','Get-BundleCache')},
    @{File='Switch-FG.ps1';Names=@('Get-VerifiedFgArchive','Expand-MfgSwitchPayload')}
)) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ManagerInstallerDir $entry.File),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Local installer source could not be parsed.' }
    foreach ($name in $entry.Names) {
        $definitions=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name })
        if ($definitions.Count -ne 1) { throw "Missing or ambiguous local installer function: $name" }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
}
function Get-ManagerLatest([string]$WorkDir) {
    $WorkDir=[IO.Path]::GetFullPath($WorkDir)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $path=Get-LatestBundleLock (Get-ProfilePath $WorkDir 'metadata')
    $lock=Read-BundleLock $path
    return [pscustomobject]@{Lock=$lock;LockPath=$path;WorkDir=$WorkDir;Cache=(Get-ProfilePath $WorkDir 'cache')}
}
function Assert-ManagerLatest($Latest) {
    if (-not $Latest -or -not $Latest.LockPath -or -not $Latest.WorkDir -or -not $Latest.Cache) { throw 'Check for the latest bundle first.' }
    $lock=Read-BundleLock $Latest.LockPath
    if ($lock.release_tag -cne $Latest.Lock.release_tag -or $lock.mochizuki.tag -cne 'v0.0.9') { throw 'Unsupported or changed bundle metadata; check for updates again.' }
    return $lock
}
function Get-ManagerBackups([string]$Game) {
    $Game=[IO.Path]::GetFullPath($Game).TrimEnd([char[]]'\/')
    $root=Get-ProfilePath $Game '.optiscaler-bundle-backups'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $result=@()
    foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory)) {
        try {
            $relative='.optiscaler-bundle-backups/'+$dir.Name+'/manifest.json'
            $path=Get-ProfilePath $Game $relative
            if (Test-Path -LiteralPath (Get-ProfilePath $Game ('.optiscaler-bundle-backups/'+$dir.Name+'/.restored'))) { continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ([IO.Path]::GetFullPath([string]$manifest.game).TrimEnd([char[]]'\/') -ine $Game -or -not @($manifest.files).Count) { continue }
            foreach ($f in $manifest.files) { [void](Get-ProfilePath $Game $f.path) }
            $result+=[pscustomobject]@{Path=$dir.FullName;Profile=$manifest.profile;Time=(Get-Item -LiteralPath $path).LastWriteTime;Mode=$manifest.mode}
        } catch { continue }
    }
    return @($result | Sort-Object Time -Descending)
}
function Assert-ManagerFreshFolder([string]$Game) {
    if (-not (Test-Path -LiteralPath $Game -PathType Container)) { throw 'Game folder does not exist.' }
    foreach ($relative in @('OptiScaler','OptiScaler.ini','dlssnr-amd','dlssnr-amd.ini','dlssnr-amd-install.txt','dlssnr-amd-backup','openrr-amd','openrr-amd.ini','dxgi.dll','d3d11.dll','d3d12.dll','version.dll','winmm.dll','winhttp.dll','dbghelp.dll','OptiScaler.dll','OptiScaler.asi','.optiscaler-bundle-backups')) {
        if (Test-Path -LiteralPath (Get-ProfilePath $Game $relative)) { throw "Existing or ambiguous installation ($relative). Use Update for a recognized bundle; fresh installation is refused." }
    }
    foreach ($dll in (Get-ChildItem -LiteralPath $Game -File -Filter '*.dll')) {
        if (Test-OptiProxy (Get-ProfilePath $Game $dll.Name)) { throw 'An existing OptiScaler proxy was found. Use Update instead of Install.' }
    }
    Assert-ProfileStopped $Game
}
function Get-ManagerGameStatus([string]$Game) {
    $Game=[IO.Path]::GetFullPath($Game).TrimEnd([char[]]'\/')
    $state='Unsupported'; $mode='Unknown'; $version=''; $reason=''; $rr=$false
    try {
        $target=Assert-GameUpdateTarget $Game; $state='Existing'
        if ($target.state) { $version=[string]$target.state.release_tag }
        try { $mode=(Get-BundleFgStatus $Game).Mode } catch { $reason=$_.Exception.Message }
        $rr=Test-Path -LiteralPath (Get-ProfilePath $Game 'OptiScaler/plugins/openrr-amd.asi') -PathType Leaf
    } catch {
        $initialReason=$_.Exception.Message
        if ($initialReason -like '*Close the game*') { $reason=$initialReason }
        else { try { Assert-ManagerFreshFolder $Game; $state='Fresh' } catch { $reason=$_.Exception.Message } }
    }
    $backups=@(); try { $backups=@(Get-ManagerBackups $Game) } catch { }
    return [pscustomobject]@{State=$state;Mode=$mode;Version=$version;CanRollback=($backups.Count -gt 0);OpenRR=$rr;Reason=$reason;Running=($reason -like '*Close the game*');Game=$Game}
}
function Update-ManagerGame([string]$Game,$Latest) {
    $target=Assert-GameUpdateTarget $Game; $lock=Assert-ManagerLatest $Latest
    if (Test-GameBundleCurrent $target $lock) { return [pscustomobject]@{Changed=$false;Backup=$null;Game=$target.game;Version=$lock.release_tag} }
    $payload=Get-BundleCache $lock $Latest.LockPath $Latest.Cache
    $backup=Update-InstalledGame $target.game $payload $lock
    return [pscustomobject]@{Changed=($null -ne $backup);Backup=$backup;Game=$target.game;Version=$lock.release_tag}
}
function Set-ManagerFg([string]$Game,[ValidateSet('ANR','XeMFG')][string]$Mode,$Latest) {
    $status=Get-BundleFgStatus $Game; $stage=$null; $anr=$null; $mfg=$null
    try {
        if (($Mode -eq 'ANR' -and -not $status.HasAnr) -or ($Mode -eq 'XeMFG' -and -not $status.HasMfg)) {
            $lock=Assert-ManagerLatest $Latest
            $stage=Get-ProfilePath $Latest.WorkDir ('fg-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            if ($Mode -eq 'ANR') {
                $archive=Join-Path $stage 'anr.zip'; Get-VerifiedFgArchive $lock.anr ANR $archive
                Expand-ProfileZip $archive (Join-Path $stage 'anr') anr
                $anr=Join-Path $stage 'anr/Apex Neural Rendering FG'
            } else {
                $archive=Join-Path $stage 'mfg.zip'; Get-VerifiedFgArchive $lock.mfgunlocker MFG $archive
                $mfg=Join-Path $stage 'MFGUnlocker.asi'; Expand-MfgSwitchPayload $archive $mfg
            }
        }
        $backup=Set-BundleFgMode $status.Game $Mode $anr $mfg
        return [pscustomobject]@{Changed=($null -ne $backup);Backup=$backup;Mode=$Mode;Game=$status.Game}
    } finally { if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}
function Enable-ManagerOpenRR([string]$Game,[string]$RrDll,$Latest) {
    $target=Assert-GameUpdateTarget $Game; $Game=$target.game
    Assert-RrModel $RrDll
    foreach ($relative in @('OptiScaler/plugins/openrr-amd.asi','openrr-amd','openrr-amd.ini')) {
        if (Test-Path -LiteralPath (Get-ProfilePath $Game $relative)) { throw 'OpenRR is already present or partially installed. It was preserved, not reinstalled.' }
    }
    $lock=Assert-ManagerLatest $Latest; $stage=Get-ProfilePath $Latest.WorkDir ('rr-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $handle=$null
    try {
        $archive=Join-Path $stage 'openrr.zip'; Get-Asset $lock.openrr OpenRR $archive
        Expand-ProfileZip $archive (Join-Path $stage 'openrr') openrr
        $handle=[IO.File]::Open((Get-ProfilePath $Game '.optiscaler-bundle-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        foreach ($relative in @('OptiScaler/plugins/openrr-amd.asi','openrr-amd','openrr-amd.ini')) { if (Test-Path -LiteralPath (Get-ProfilePath $Game $relative)) { throw 'OpenRR appeared during preparation; nothing was overwritten.' } }
        if ($handle.Length -ne 0) { throw 'Reserved lock path contains data.' }
        $before=@(Get-ManagerBackups $Game | ForEach-Object { $_.Path })
        Apply-OptionalProfile $Game $stage openrr $RrDll
        $backup=@(Get-ManagerBackups $Game | Where-Object { $_.Path -notin $before } | Select-Object -First 1)
        return [pscustomobject]@{Changed=$true;Backup=$(if ($backup.Count) {$backup[0].Path} else {$null});Game=$Game}
    } finally { if ($handle) { $handle.Dispose() }; if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}
function Restore-ManagerBackup([string]$Game,[string]$Backup) {
    $Game=[IO.Path]::GetFullPath($Game).TrimEnd([char[]]'\/')
    if (-not @(Get-ManagerBackups $Game | Where-Object { $_.Path -ieq [IO.Path]::GetFullPath($Backup) }).Count) { throw 'Choose a valid backup belonging to this game.' }
    $handle=[IO.File]::Open((Get-ProfilePath $Game '.optiscaler-bundle-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { if ($handle.Length -ne 0) { throw 'Reserved lock path contains data.' }; Restore-OptionalProfile $Game $Backup; [IO.File]::WriteAllText((Get-ProfilePath $Backup '.restored'),[DateTime]::UtcNow.ToString('o')); return [pscustomobject]@{Changed=$true;Game=$Game;Backup=$Backup} } finally { $handle.Dispose() }
}
function Assert-ManagerNrDll([string]$Path) {
    if ([IO.Path]::GetFileName($Path) -ine 'nvngx_dlssnr.dll' -or -not (Test-UpdatePe $Path)) { throw 'Select your own x64 nvngx_dlssnr.dll (310.9.16 or 310.8.0).' }
    $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($v.FileMajorPart -ne 310 -or "$($v.FileMinorPart).$($v.FileBuildPart)" -notin @('9.16','8.0')) { throw 'NR requires nvngx_dlssnr.dll version 310.9.16 or 310.8.0.' }
}
function Assert-ManagerInstallCode([string]$Payload,[string]$Archive,[string]$Sha) {
    if (-not (Test-Sha $Archive $Sha)) { throw 'Mochizuki source ZIP is not verified.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen=@{}
        foreach ($member in $zip.Entries) {
            $name=$member.FullName.Replace('\','/')
            if ($name -ne 'install.ps1' -and -not $name.StartsWith('model-tools/')) { continue }
            if ($name.EndsWith('/')) { continue }
            $path=Get-ProfilePath $Payload $name
            if ($seen.ContainsKey($name)) { throw 'Duplicate installer code in source ZIP.' }; $seen[$name]=$true
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing verified installer file: $name" }
            $stream=$member.Open(); $sha256=[Security.Cryptography.SHA256]::Create()
            try { $hash=([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-','').ToLowerInvariant() } finally { $sha256.Dispose(); $stream.Dispose() }
            if ((Get-UpdateHash $path) -cne $hash) { throw "Cached installer code differs from its source archive: $name" }
        }
        foreach ($name in @('install.ps1','model-tools/dlssnr_extract_model.exe','model-tools/dlssnr-int4-weights.exe')) { if (-not $seen.ContainsKey($name)) { throw "Verified source lacks $name" } }
        foreach ($file in (Get-ChildItem -LiteralPath (Get-ProfilePath $Payload 'model-tools') -Recurse -File)) {
            $name=$file.FullName.Substring($Payload.TrimEnd([char[]]'\/').Length+1).Replace('\','/')
            if (-not $seen.ContainsKey($name)) { throw 'Unexpected file beside the model tools.' }
        }
    } finally { $zip.Dispose() }
}
function Invoke-ManagerFirstInstall([string]$Payload,[string]$Exe,[string]$NrDll) {
    if (-not $env:SystemRoot) { throw 'First installation requires Windows.' }
    $powershell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw 'Windows PowerShell is unavailable.' }
    $script=Get-ProfilePath $Payload 'install.ps1'
    foreach ($value in @($script,$Exe,$NrDll)) { if ($value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) { throw 'Unsupported characters in installation path.' } }
    $start=[Diagnostics.ProcessStartInfo]::new(); $start.FileName=$powershell
    $start.Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Target `"$Exe`" -Route optiscaler -Dll `"$NrDll`" -Model CC_SILVER_AARDWOLD -Network default -RenoDX on -Lumenite off"
    $start.WorkingDirectory=$Payload; $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start(); $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit(); $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult()
        if ($out) { Write-Host $out }; if ($err) { Write-Host $err }
        if ($process.ExitCode -ne 0) { throw "Official first installer exited with code $($process.ExitCode). Keep any partial installation and its manifest; do not retry as a fresh install." }
    } finally { $process.Dispose() }
}
function Test-ManagerGameExe([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    try {
        $reader=[IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 90 -or $reader.ReadUInt16() -ne 0x5a4d) { return $false }
        $stream.Position=60; $offset=$reader.ReadUInt32()
        if ($offset -gt $stream.Length-26) { return $false }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { return $false }
        $stream.Position=$offset+22
        return (($reader.ReadUInt16() -band 0x2000) -eq 0)
    } finally { $stream.Dispose() }
}
function Install-ManagerGame([string]$Exe,[string]$DlsnrDll,$Latest) {
    $Exe=[IO.Path]::GetFullPath($Exe)
    if ([IO.Path]::GetExtension($Exe) -ine '.exe' -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw 'Select the actual game EXE.' }
    $Game=Split-Path -Parent $Exe; Assert-ManagerFreshFolder $Game
    [void](Get-ProfilePath $Game ([IO.Path]::GetFileName($Exe)))
    if (-not (Test-ManagerGameExe $Exe)) { throw 'The selected game executable must be x64 PE, not a DLL.' }
    Assert-ManagerNrDll $DlsnrDll
    $lock=Assert-ManagerLatest $Latest
    $payload=Get-BundleCache $lock $Latest.LockPath $Latest.Cache
    $archive=Get-ReusableZip $lock.mochizuki Mochizuki $Latest.Cache
    Assert-ManagerInstallCode $payload $archive $lock.mochizuki.sha256
    $handle=[IO.File]::Open((Get-ProfilePath $Game '.optiscaler-bundle-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if ($handle.Length -ne 0) { throw 'Reserved lock path contains data.' }
        Assert-ManagerFreshFolder $Game
        # Fail here, before upstream's automatic elevation path can run.
        $probe=Get-ProfilePath $Game ('.manager-write-'+[guid]::NewGuid().ToString('N'))
        try { [IO.File]::WriteAllText($probe,'') } finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
        $payloadLease=$null
        try {
            $payloadLease=[IO.File]::Open((Get-ProfilePath $payload '.manager-model-preparation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            if ($payloadLease.Length -ne 0) { throw 'Reserved model-preparation lock contains data.' }
            Invoke-ManagerFirstInstall $payload $Exe ([IO.Path]::GetFullPath($DlsnrDll))
        } finally { if ($payloadLease) { $payloadLease.Dispose() } }
        [void](Assert-GameUpdateTarget $Game)
    } finally { $handle.Dispose() }
    # Stamp installed managed hashes with the same preservation rules as later updates.
    $backup=Update-InstalledGame $Game $payload $lock
    return [pscustomobject]@{Changed=$true;Game=$Game;Version=$lock.release_tag;Backup=$backup}
}
