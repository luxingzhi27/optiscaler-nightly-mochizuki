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
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('bundle-update-test-' + [guid]::NewGuid().ToString('N'))
try {
    $game=Join-Path $tmp 'game'; $payload=Join-Path $tmp 'payload'
    Put (Join-Path $game 'OptiScaler.ini') "[FrameGen]`nFGInput=nvngxfg`nFGNvngxReplacement=Apex Neural Rendering FG`n[Plugins]`nLoadAsiPlugins=true"
    Put (Join-Path $game 'dlssnr-amd.ini') 'keep my NR settings'
    Put (Join-Path $game 'dlssnr-amd-install.txt') "F dlssnr-amd-install.txt`nF OptiScaler.ini`nF winmm.dll`nD OptiScaler`nD dlssnr-amd"
    Put-Pe (Join-Path $game 'winmm.dll') 1
    Put-Pe (Join-Path $game 'dxgi.dll') 3 'ReShade.dll'
    Put-Pe (Join-Path $game 'OptiScaler/plugins/dlssnr-amd.asi') 1 'Mochizuki.dll'
    Put (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi.disabled-anr') 'leave disabled MFG exactly'
    Put (Join-Path $game 'OptiScaler/plugins/openrr-amd.asi') 'leave OpenRR exactly'
    Put (Join-Path $game 'OptiScaler/custom/Apex Neural Rendering FG/dlssg/nvngx_dlssg.dll') 'leave ANR exactly'
    Put (Join-Path $game 'dlssnr-amd/CC_SILVER_AARDWOLD.bin') 'keep extracted model'
    Put (Join-Path $game 'dlssnr-amd/int4/settings.txt') 'keep tuning'
    Put (Join-Path $game 'dlssnr-amd/shaders/a.spv') 'old shader'
    Put (Join-Path $game 'openrr-amd/nvngx_dlssd.dll') 'keep RR model'
    Put (Join-Path $game 'openrr-amd.ini') 'keep RR ini'
    Put-Pe (Join-Path $payload 'optiscaler/release/OptiScaler.dll') 2
    Put-Pe (Join-Path $payload 'optiscaler/release/OptiScaler/libxess.dll') 2 'libxess.dll'
    Put-Pe (Join-Path $payload 'optiscaler/release/OptiScaler/plugins/MFGUnlocker.asi') 2 'MFGUnlocker.dll'
    Put-Pe (Join-Path $payload 'optiscaler/asi/dlssnr-amd.asi') 2 'Mochizuki.dll'
    Put (Join-Path $payload 'optiscaler/asi/nr_present_probe.exe') 'new probe never run'
    Put (Join-Path $payload 'optiscaler/release/OptiScaler.ini') 'do not use new defaults'
    Put (Join-Path $payload 'optiscaler/release/OptiScaler/streamlined_fetcher_windows.bat') 'do not copy or execute'
    Put (Join-Path $payload 'dlssnr-amd/shaders/a.spv') 'new shader'
    Put (Join-Path $payload 'dlssnr-amd/CC_SILVER_AARDWOLD.bin') 'forbidden replacement'
    Put (Join-Path $payload 'dlssnr-amd/int4/settings.txt') 'new defaults'
    $lock=@{schema_version=3;release_tag='test-v3';mochizuki=@{tag='v0.0.9'}}
    $protected=@('OptiScaler.ini','dlssnr-amd.ini','dlssnr-amd/CC_SILVER_AARDWOLD.bin','dlssnr-amd/int4/settings.txt','OptiScaler/plugins/MFGUnlocker.asi.disabled-anr','OptiScaler/plugins/openrr-amd.asi','OptiScaler/custom/Apex Neural Rendering FG/dlssg/nvngx_dlssg.dll','openrr-amd/nvngx_dlssd.dll','openrr-amd.ini','dxgi.dll','dlssnr-amd-install.txt')
    $hashes=@{}; foreach ($p in $protected) { $hashes[$p]=Get-UpdateHash (Join-Path $game $p) }
    Check (Test-OptiProxy (Join-Path $game 'winmm.dll')) 'Synthetic PE export identity rejected.'
    Check (-not (Test-OptiProxy (Join-Path $game 'dxgi.dll'))) 'Unrelated PE accepted as OptiScaler.'
    $target=Assert-GameUpdateTarget $game
    Check ($target.proxy -eq 'winmm.dll') 'Proxy filename changed.'
    $backup=Update-InstalledGame $game $payload $lock
    Check ((Get-UpdateHash (Join-Path $game 'winmm.dll')) -eq (Get-UpdateHash (Join-Path $payload 'optiscaler/release/OptiScaler.dll'))) 'Core not updated.'
    Check ((Get-Content -Raw (Join-Path $game 'dlssnr-amd/shaders/a.spv')) -ceq 'new shader') 'NR runtime not updated.'
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi'))) 'Disabled MFG reenabled.'
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/streamlined_fetcher_windows.bat'))) 'Fetcher BAT copied.'
    foreach ($p in $protected) { Check ((Get-UpdateHash (Join-Path $game $p)) -eq $hashes[$p]) "Protected file changed: $p" }
    Check (Test-GameBundleCurrent (Assert-GameUpdateTarget $game) $lock) 'Current-version check failed.'
    $same=Update-InstalledGame $game $payload $lock
    Check ($null -eq $same) 'Same release was not a no-op.'
    Put (Join-Path $game 'OptiScaler/libxess.dll') 'user modified runtime'
    Check (-not (Test-GameBundleCurrent (Assert-GameUpdateTarget $game) $lock)) 'Modified runtime considered current.'
    Expect-Failure { Update-InstalledGame $game $payload $lock }
    Copy-Item (Join-Path $payload 'optiscaler/release/OptiScaler/libxess.dll') (Join-Path $game 'OptiScaler/libxess.dll') -Force
    Restore-OptionalProfile $game $backup
    Check ((Get-Content -Raw (Join-Path $game 'dlssnr-amd/shaders/a.spv')) -ceq 'old shader') 'Rollback did not restore shader.'
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/.bundle-update-state.json'))) 'Rollback left new state.'
    foreach ($p in $protected) { Check ((Get-UpdateHash (Join-Path $game $p)) -eq $hashes[$p]) "Rollback changed protected file: $p" }
    Put-Pe (Join-Path $game 'version.dll') 9
    Expect-Failure { Assert-GameUpdateTarget $game }
    Remove-Item (Join-Path $game 'version.dll')
    # Existing unrelated/invalid named plugins must not be overwritten.
    Remove-Item (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi.disabled-anr')
    Put (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi') 'not a DLL'
    Expect-Failure { Update-InstalledGame $game $payload $lock }
    Put-Pe (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi') 1 'MFGUnlocker.dll'
    Put-Pe (Join-Path $game 'OptiScaler/plugins/OptiPatcher.asi') 1 'OptiPatcher.dll'
    Put-Pe (Join-Path $payload 'optiscaler/release/OptiScaler/plugins/OptiPatcher.asi') 2 'OptiPatcher.dll'
    # Never accept an upstream copy of a user's NVIDIA runtime/model as a managed update.
    Put (Join-Path $game 'OptiScaler/nvngx_dlss.dll') 'user NVIDIA DLL'
    Put (Join-Path $payload 'optiscaler/release/OptiScaler/nvngx_dlss.dll') 'must not replace NVIDIA DLL'
    Put (Join-Path $game 'OptiScaler/model.bin') 'user model'
    Put (Join-Path $payload 'optiscaler/release/OptiScaler/model.bin') 'must not replace model'
    $oldProxy=Get-UpdateHash (Join-Path $game 'winmm.dll')
    $script:injectFailure=$true
    function Copy-Item {
        param([string]$LiteralPath,[string]$Destination,[switch]$Force)
        if ($script:injectFailure -and $LiteralPath -eq (Join-Path $payload 'optiscaler/release/OptiScaler/libxess.dll')) {
            $script:injectFailure=$false
            throw 'Synthetic interrupted copy'
        }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    try { Expect-Failure { Update-InstalledGame $game $payload $lock } }
    finally { Remove-Item Function:\Copy-Item }
    Check ((Get-UpdateHash (Join-Path $game 'winmm.dll')) -eq $oldProxy) 'Failed update did not roll back proxy.'
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/.bundle-update-state.json'))) 'Failed update left marker.'
    $backup=Update-InstalledGame $game $payload $lock
    Check ((Get-UpdateHash (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi')) -eq (Get-UpdateHash (Join-Path $payload 'optiscaler/release/OptiScaler/plugins/MFGUnlocker.asi'))) 'Enabled MFG not updated.'
    Check ((Get-Content -Raw (Join-Path $game 'OptiScaler/nvngx_dlss.dll')) -ceq 'user NVIDIA DLL') 'NVIDIA DLL modified.'
    Check ((Get-Content -Raw (Join-Path $game 'OptiScaler/model.bin')) -ceq 'user model') 'OptiScaler model modified.'
    Restore-OptionalProfile $game $backup
    $lock.mochizuki.tag='v0.0.10' 
    Expect-Failure { Update-InstalledGame $game $payload $lock }
    Write-Host 'PASS: PE export identity, named-proxy preservation, unrelated DLL protection, configurations/models/optional payload preservation, disabled MFG preservation, runtime upgrade, no-op, modified-file guard, rollback, ambiguous proxy and unknown model ABI rejection.'
} finally { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
