$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach ($file in @('OptionalProfiles.ps1','GameUpdate.ps1')) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root "installer/$file"),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { $errors | Format-List; throw "Parse failure: $file" }
    . (Join-Path $root "installer/$file")
}
function Check($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Expect-Failure([scriptblock]$Action) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed 'Expected refusal.' }
function Put([string]$Path,[string]$Text) { New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null; [IO.File]::WriteAllText($Path,$Text) }
function Put-Pe([string]$Path,[byte]$Marker=1,[string]$ImageName='OptiScaler.dll') {
    $bytes=[byte[]]::new(1024)
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[60]=0x80
    $bytes[128]=0x50; $bytes[129]=0x45; $bytes[132]=0x64; $bytes[133]=0x86
    $bytes[134]=1; $bytes[148]=0xf0; $bytes[151]=0x20; $bytes[152]=0x0b; $bytes[153]=0x02
    # PE32+ exports: RVA 0x1000 maps to raw offset 0x200. Export name at RVA 0x1040.
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes,264)
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes,404)
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes,408)
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes,412)
    [BitConverter]::GetBytes([uint32]0x1040).CopyTo($bytes,524)
    [Text.Encoding]::ASCII.GetBytes($ImageName + "`0").CopyTo($bytes,576)
    $bytes[900]=$Marker
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllBytes($Path,$bytes)
}

. (Join-Path $root 'manager/ManagerEngine.ps1')
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('manager-engine-'+[guid]::NewGuid().ToString('N'))
try {
    $game=Join-Path $tmp 'Fresh game'; $exe=Join-Path $game 'Game.exe'
    Put-Pe $exe 1 'Game.exe'; $b=[IO.File]::ReadAllBytes($exe);$b[151]=0;[IO.File]::WriteAllBytes($exe,$b)
    Check (Test-ManagerGameExe $exe) 'x64 EXE not accepted.'
    Check ((Get-ManagerGameStatus $game).State -eq 'Fresh') 'Clean game not fresh.'
    Put (Join-Path $game 'dxgi.dll') 'unrelated proxy'
    Check ((Get-ManagerGameStatus $game).State -eq 'Unsupported') 'Unrelated proxy not guarded.'
    Expect-Failure { Install-ManagerGame $exe 'missing.dll' $null }
    Remove-Item (Join-Path $game 'dxgi.dll')
    $latest=[pscustomobject]@{LockPath=(Join-Path $tmp 'versions.lock.json');WorkDir=$tmp;Cache=(Join-Path $tmp 'cache');Lock=@{release_tag='bundle-20261116-aaaaaaaaaaaaaaaaaaaa'}}
    $lock=@{schema_version=3;installer_edition=1;release_tag=$latest.Lock.release_tag;mochizuki=@{tag='v0.0.9';sha256=('a'*64)}}
    Put $latest.LockPath ($lock | ConvertTo-Json -Depth 5)
    Check ((Assert-ManagerLatest $latest).release_tag -eq $lock.release_tag) 'Local lock validation failed.'
    # Integrity gate: synthetic official ZIP, no binary execution.
    $payload=Join-Path $tmp 'payload'; $source=Join-Path $tmp 'zip-source'
    foreach ($r in @('install.ps1','model-tools/dlssnr_extract_model.exe','model-tools/dlssnr-int4-weights.exe','model-tools/readme.txt')) { Put (Join-Path $source $r) "trusted $r"; Put (Join-Path $payload $r) "trusted $r" }
    $archive=Join-Path $tmp 'upstream.zip'; Compress-Archive -Path (Join-Path $source '*') -DestinationPath $archive
    $hash=Get-UpdateHash $archive
    Assert-ManagerInstallCode $payload $archive $hash
    Put (Join-Path $payload 'model-tools/evil.dll') 'untrusted'
    Expect-Failure { Assert-ManagerInstallCode $payload $archive $hash }
    Remove-Item (Join-Path $payload 'model-tools/evil.dll')
    Put (Join-Path $payload 'install.ps1') 'tampered'
    Expect-Failure { Assert-ManagerInstallCode $payload $archive $hash }
    Put (Join-Path $payload 'install.ps1') 'trusted install.ps1'
    # Mock only network/preparation/upstream execution; the manager refusal and dispatch stay real.
    $script:launched=0; $script:updates=0
    function Get-BundleCache { param($Lock,$LockFile,$Cache) return $payload }
    function Get-ReusableZip { param($Asset,$Kind,$Cache) return $archive }
    function Assert-ManagerNrDll { param($Path) if ($Path -ne 'cached-nvngx_dlssnr.dll') { throw 'wrong local model path' } }
    function Assert-ManagerInstallCode { param($Payload,$Archive,$Sha) }
    function Invoke-ManagerFirstInstall { param($Payload,$Exe,$NrDll)
        $script:launched++
        Put (Join-Path $game 'OptiScaler.ini') "[FrameGen]`nFGInput=upscaler`nFGOutput=xefg`nFGNvngxReplacement=None`nDisableHudless=false`n[Plugins]`nLoadAsiPlugins=true"
        Put (Join-Path $game 'dlssnr-amd.ini') 'original NR tuning'
        Put (Join-Path $game 'dlssnr-amd-install.txt') "F OptiScaler.ini`nF dxgi.dll`nD OptiScaler`nD dlssnr-amd"
        Put-Pe (Join-Path $game 'dxgi.dll') 1
        Put-Pe (Join-Path $game 'OptiScaler/plugins/dlssnr-amd.asi') 1 'Mochi.dll'
        Put-Pe (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi') 1 'MFG.dll'
        Put (Join-Path $game 'dlssnr-amd/model.bin') 'cached model'
    }
    $realUpdate=(Get-Command Update-InstalledGame).ScriptBlock
    function Update-InstalledGame { param($Game,$Payload,$Lock) $script:updates++; return $null }
    $result=Install-ManagerGame $exe 'cached-nvngx_dlssnr.dll' $latest
    Check ($result.Changed -and $script:launched -eq 1 -and $script:updates -eq 1) 'Fresh install dispatch failed.'
    Check ((Get-ManagerGameStatus $game).State -eq 'Existing') 'Installed game not recognized.'
    $iniHash=Get-UpdateHash (Join-Path $game 'dlssnr-amd.ini')
    Expect-Failure { Install-ManagerGame $exe 'cached-nvngx_dlssnr.dll' $latest }
    Check ($script:launched -eq 1) 'Fresh installer ran on existing installation.'
    [void](Update-ManagerGame $game $latest)
    Check ($script:updates -eq 2 -and (Get-UpdateHash (Join-Path $game 'dlssnr-amd.ini')) -eq $iniHash) 'Update reset settings.'
    # Existing FG needs no latest metadata or downloads.
    function Get-VerifiedFgArchive { throw 'Network must not run for an installed provider.' }
    $r=Set-ManagerFg $game XeMFG $null
    Check (-not $r.Changed -and $r.Mode -eq 'XeMFG') 'Installed FG no-op failed.'
    Put (Join-Path $game 'openrr-amd.ini') 'RR user tuning'
    function Assert-RrModel { param($Path) }
    Expect-Failure { Enable-ManagerOpenRR $game 'local-rr.dll' $null }
    Check ((Get-Content (Join-Path $game 'openrr-amd.ini') -Raw) -eq 'RR user tuning') 'Existing RR overwritten.'
    # Real snapshot listing and guarded restore.
    $backup=Join-Path $game '.optiscaler-bundle-backups/test'
    Put (Join-Path $backup 'files/dlssnr-amd.ini') 'before tuning'
    $manifest=@{game=$game;profile='fg-switch';files=@(@{path='dlssnr-amd.ini';existed=$true;before=(Get-UpdateHash (Join-Path $backup 'files/dlssnr-amd.ini'));after=$iniHash})}
    Put (Join-Path $backup 'manifest.json') ($manifest | ConvertTo-Json -Depth 6)
    Check (@(Get-ManagerBackups $game).Count -eq 1) 'Backup not listed.'
    $r=Restore-ManagerBackup $game $backup
    Check ($r.Changed -and (Get-Content (Join-Path $game 'dlssnr-amd.ini') -Raw) -eq 'before tuning') 'Restore failed.'
    Expect-Failure { Restore-ManagerBackup $game $backup }
    Check (@(Get-ManagerBackups $game).Count -eq 0) 'Consumed backup remained selectable.'
    # Two independently adopted legacy installs: real update core and offline switching.
    Set-Item Function:\Update-InstalledGame $realUpdate
    $game1=$game; $game=Join-Path $tmp 'Second legacy game'
    Invoke-ManagerFirstInstall $payload (Join-Path $game 'Game.exe') 'local'
    Put (Join-Path $game 'dlssnr-amd.ini') 'second game NR settings'
    Put-Pe (Join-Path $payload 'optiscaler/release/OptiScaler.dll') 3
    Put-Pe (Join-Path $payload 'optiscaler/release/OptiScaler/plugins/MFGUnlocker.asi') 3 'MFG.dll'
    Put-Pe (Join-Path $payload 'optiscaler/asi/dlssnr-amd.asi') 3 'Mochi.dll'
    Put (Join-Path $payload 'optiscaler/asi/nr_present_probe.exe') 'never execute'
    Put (Join-Path $payload 'dlssnr-amd/shaders/a.spv') 'new shader'
    [void](Update-ManagerGame $game1 $latest)
    $firstState=Get-UpdateHash (Join-Path $game1 'OptiScaler/.bundle-update-state.json')
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/.bundle-update-state.json'))) 'Update leaked to second game.'
    [void](Update-ManagerGame $game $latest)
    Check ((Get-UpdateHash (Join-Path $game1 'OptiScaler/.bundle-update-state.json')) -eq $firstState) 'Second update touched first game.'
    Check ((Get-Content (Join-Path $game1 'dlssnr-amd.ini') -Raw) -eq 'before tuning') 'First game settings lost.'
    Check ((Get-Content (Join-Path $game 'dlssnr-amd.ini') -Raw) -eq 'second game NR settings') 'Second game settings lost.'
    $provider=Join-Path $game1 'OptiScaler/custom/Apex Neural Rendering FG/dlssg'
    Put-Pe (Join-Path $provider 'nvngx_dlssg.dll') 3 'ANR.dll'
    foreach ($r in @('nr_fg.ini','path_table.json','size_table.json','adapters/pack.nrx','kernels/pack.nrx','kernels-portable/pack.nrx')) { Put (Join-Path $provider $r) 'local ANR data' }
    foreach ($b in @('coopmat','dp4a','packed','portable-linalg','portable','portable-xmx')) { foreach ($f in @('pq10','srgb8')) { Put (Join-Path $provider "programs/fg-lite-any-$b-$f/pack.nrx") 'program' } }
    $secondIni=Get-UpdateHash (Join-Path $game 'OptiScaler.ini'); $secondState=Get-UpdateHash (Join-Path $game 'OptiScaler/.bundle-update-state.json')
    $r=Set-ManagerFg $game1 ANR $null
    Check ($r.Changed -and $r.Mode -eq 'ANR') 'Offline installed ANR switch failed.'
    Check ((Get-UpdateHash (Join-Path $game 'OptiScaler.ini')) -eq $secondIni -and (Get-UpdateHash (Join-Path $game 'OptiScaler/.bundle-update-state.json')) -eq $secondState) 'Switch modified the other game.'
    Write-Host 'Manager engine tests passed; upstream execution was mocked.'
} finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
