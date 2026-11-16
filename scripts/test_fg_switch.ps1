$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach ($file in @('OptionalProfiles.ps1','GameUpdate.ps1','FgSwitch.ps1')) {
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
function Hash([string]$Relative) { Get-UpdateHash (Join-Path $game $Relative) }
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('fg-switch-test-'+[guid]::NewGuid().ToString('N'))
try {
    $game=Join-Path $tmp 'Game folder'; $provider=Join-Path $tmp 'Apex Neural Rendering FG'
    Put (Join-Path $game 'OptiScaler.ini') "[FrameGen]`nFGInput=upscaler`nFGOutput=xefg`nFGNvngxReplacement=None`nDisableHudless=false`nFrameGenMultiplier=3`n[Plugins]`nLoadAsiPlugins=true"
    Put (Join-Path $game 'dlssnr-amd.ini') 'NR settings'
    Put (Join-Path $game 'dlssnr-amd-install.txt') "F OptiScaler.ini`nF winmm.dll`nD OptiScaler`nD dlssnr-amd"
    Put-Pe (Join-Path $game 'winmm.dll') 1
    Put-Pe (Join-Path $game 'OptiScaler/plugins/dlssnr-amd.asi') 1 'Mochi.dll'
    Put-Pe (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi') 2 'MFG.dll'
    Put (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.ini') 'MFG tuning'
    Put (Join-Path $game 'openrr-amd.ini') 'RR settings'
    Put (Join-Path $game 'openrr-amd/nvngx_dlssd.dll') 'RR model'
    Put (Join-Path $game 'dlssnr-amd/model.bin') 'NR model'
    Put-Pe (Join-Path $provider 'dlssg/nvngx_dlssg.dll') 3 'ANR.dll'
    foreach ($r in @('nr_fg.ini','path_table.json','size_table.json','adapters/pack.nrx','kernels/pack.nrx','kernels-portable/pack.nrx')) { Put (Join-Path $provider "dlssg/$r") "keep $r" }
    foreach ($backend in @('coopmat','dp4a','packed','portable-linalg','portable','portable-xmx')) { foreach ($format in @('pq10','srgb8')) { Put (Join-Path $provider "dlssg/programs/fg-lite-any-$backend-$format/pack.nrx") 'program bytes' } }
    $mfgHash=Hash 'OptiScaler/plugins/MFGUnlocker.asi'
    $state=@{schema_version=1;proxy='winmm.dll';release_tag='test';files=@(@{path='winmm.dll';sha256=(Hash 'winmm.dll')},@{path='OptiScaler/plugins/MFGUnlocker.asi';sha256=$mfgHash})}
    Put (Join-Path $game 'OptiScaler/.bundle-update-state.json') ($state | ConvertTo-Json -Depth 8)
    $protected=@{}; foreach ($r in @('dlssnr-amd.ini','openrr-amd.ini','openrr-amd/nvngx_dlssd.dll','dlssnr-amd/model.bin','OptiScaler/plugins/MFGUnlocker.ini')) { $protected[$r]=Hash $r }
    $s=Get-BundleFgStatus $game; Check ($s.Mode -eq 'XeMFG' -and $s.HasMfg -and -not $s.HasAnr) 'Initial status wrong.'
    $initialIni=Hash 'OptiScaler.ini'
    $coexist=Enable-ManagerCoexistingFg $game $provider
    Check ((Hash 'OptiScaler.ini') -eq $initialIni) 'Coexist installation changed FrameGen selection.'
    Check ((Get-BundleFgStatus $game).HasAnr) 'Coexist installation omitted ANR.'
    Check ($null -eq (Enable-ManagerCoexistingFg $game)) 'Installed coexist providers not a no-op.'
    # In-game menu keeps inactive replacement choices, and offers alternate DLSSG output routes.
    $iniFile=Join-Path $game 'OptiScaler.ini'; $saved=[IO.File]::ReadAllText($iniFile)
    Put $iniFile ($saved.Replace('FGNvngxReplacement=None','FGNvngxReplacement=Apex Neural Rendering FG'))
    Check ((Get-BundleFgStatus $game).Mode -eq 'XeMFG') 'Inactive ANR replacement hid selected XeMFG.'
    foreach ($output in @('dlssg','flipmeter')) {
        Put $iniFile ($saved.Replace('FGOutput=xefg',"FGOutput=$output").Replace('FGNvngxReplacement=None','FGNvngxReplacement=Apex Neural Rendering FG'))
        Check ((Get-BundleFgStatus $game).Mode -eq 'ANR') "Menu output $output did not recognize selected ANR."
    }
    Put $iniFile $saved
    $first=Set-BundleFgMode $game ANR
    Check ((Get-BundleFgStatus $game).Mode -eq 'ANR') 'ANR selection failed.'
    Check ((Hash 'OptiScaler/plugins/MFGUnlocker.asi') -eq $mfgHash) 'ANR removed or changed MFG.'
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi.disabled-anr'))) 'ANR disabled MFG.'
    Check (Test-GameBundleCurrent (Assert-GameUpdateTarget $game) @{schema_version=3;release_tag='test'}) 'Updater record changed unnecessarily.'
    $anrIni='OptiScaler/custom/Apex Neural Rendering FG/dlssg/nr_fg.ini'; Put (Join-Path $game $anrIni) 'user ANR tuning'
    $anrHash=Hash $anrIni
    $second=Set-BundleFgMode $game XeMFG
    Check ((Get-BundleFgStatus $game).Mode -eq 'XeMFG') 'XeMFG selection failed.'
    Check ((Hash 'OptiScaler/plugins/MFGUnlocker.asi') -eq $mfgHash) 'MFG bytes changed.'
    Check ((Hash $anrIni) -eq $anrHash) 'ANR tuning replaced.'
    Check ($null -eq (Set-BundleFgMode $game XeMFG)) 'Same-mode switch not a no-op.'
    foreach ($r in $protected.Keys) { Check ((Hash $r) -eq $protected[$r]) "Protected file changed: $r" }
    Check ((Get-Content (Join-Path $game 'OptiScaler.ini') -Raw).Contains('FrameGenMultiplier=3')) 'Unrelated FrameGen setting changed.'
    Expect-Failure { Restore-OptionalProfile $game $first }
    Restore-OptionalProfile $game $second
    Check ((Get-BundleFgStatus $game).Mode -eq 'ANR') 'Switch snapshot did not restore ANR.'
    $enabled=Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi'; $disabled=$enabled+'.disabled-anr'
    Copy-Item $enabled $disabled
    Expect-Failure { Set-BundleFgMode $game ANR }
    Expect-Failure { Enable-ManagerCoexistingFg $game }
    Remove-Item $disabled
    $original=[IO.File]::ReadAllBytes($enabled); Put-Pe $enabled 99 'MFG.dll'
    Expect-Failure { Set-BundleFgMode $game XeMFG }
    [IO.File]::WriteAllBytes($enabled,$original)
    function Make-Legacy {
        Move-Item $enabled $disabled
        $legacy=Get-Content (Join-Path $game 'OptiScaler/.bundle-update-state.json') -Raw | ConvertFrom-Json
        foreach ($r in $legacy.files) { if ($r.path -eq 'OptiScaler/plugins/MFGUnlocker.asi') { $r.path+='.disabled-anr' } }
        Put (Join-Path $game 'OptiScaler/.bundle-update-state.json') ($legacy | ConvertTo-Json -Depth 8)
    }
    Make-Legacy
    # A failure during migration rolls back both filenames and the updater record.
    $iniBefore=Hash 'OptiScaler.ini'; $stateBefore=Hash 'OptiScaler/.bundle-update-state.json'
    $script:copyCount=0
    function Copy-Item { param($LiteralPath,$Destination,[switch]$Force)
        if ($LiteralPath -notlike '*files*' -and $Destination -like '*Game folder*' -and $Destination -notlike '*.optiscaler-bundle-backups*') {
            $script:copyCount++; if ($script:copyCount -eq 2) { throw 'Injected switch copy failure' }
        }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    Expect-Failure { Set-BundleFgMode $game ANR }
    Remove-Item Function:\Copy-Item
    Check ((Hash 'OptiScaler.ini') -eq $iniBefore -and (Hash 'OptiScaler/.bundle-update-state.json') -eq $stateBefore) 'Rollback changed configuration/state.'
    Check ((Test-Path $disabled) -and -not (Test-Path $enabled)) 'Rollback lost legacy MFG.'
    [void](Set-BundleFgMode $game ANR)
    Check ((Hash 'OptiScaler/plugins/MFGUnlocker.asi') -eq $mfgHash -and -not (Test-Path $disabled)) 'ANR did not migrate legacy MFG.'
    Check (Test-GameBundleCurrent (Assert-GameUpdateTarget $game) @{schema_version=3;release_tag='test'}) 'Migration invalidated unchanged tracked hash.'
    Make-Legacy
    [void](Set-BundleFgMode $game XeMFG)
    Check ((Test-Path $enabled) -and -not (Test-Path $disabled)) 'XeMFG did not migrate legacy MFG.'
    Make-Legacy
    $iniBefore=Hash 'OptiScaler.ini'
    [void](Enable-ManagerCoexistingFg $game)
    Check ((Hash 'OptiScaler.ini') -eq $iniBefore -and (Test-Path $enabled)) 'Coexist migration changed selection or failed.'
    # Older optional installers renamed MFG without migrating the updater record.
    Move-Item $enabled $disabled
    $iniBefore=Hash 'OptiScaler.ini'
    [void](Enable-ManagerCoexistingFg $game)
    Check ((Test-Path $enabled) -and (Hash 'OptiScaler.ini') -eq $iniBefore) 'Legacy optional rename was not recovered from matching hash.'
    # Missing providers are installed together, preserving exact INI bytes and tuner files.
    Remove-Item $enabled
    Remove-Item (Join-Path $game 'OptiScaler/custom/Apex Neural Rendering FG') -Recurse -Force
    $state.files=@($state.files | Where-Object { $_.path -eq 'winmm.dll' }); Put (Join-Path $game 'OptiScaler/.bundle-update-state.json') ($state | ConvertTo-Json -Depth 8)
    Expect-Failure { Enable-ManagerCoexistingFg $game $provider }
    Check (-not (Test-Path (Join-Path $game 'OptiScaler/custom/Apex Neural Rendering FG/dlssg/nvngx_dlssg.dll'))) 'Incomplete preparation copied ANR before refusing missing MFG.'
    $mfgPayload=Join-Path $tmp 'MFGUnlocker.asi'; Put-Pe $mfgPayload 8 'MFG.dll'
    $iniBefore=Hash 'OptiScaler.ini'
    [void](Enable-ManagerCoexistingFg $game $provider $mfgPayload)
    Check ((Hash 'OptiScaler.ini') -eq $iniBefore) 'Installing providers changed FrameGen selection.'
    Check ((Get-BundleFgStatus $game).HasAnr -and (Test-Path $enabled)) 'Missing providers not installed together.'
    Check (-not (Test-GameBundleCurrent (Assert-GameUpdateTarget $game) @{schema_version=3;release_tag='test'})) 'Untracked MFG failed to invalidate current-release marker.'
    foreach ($r in $protected.Keys) { Check ((Hash $r) -eq $protected[$r]) "Protected file changed: $r" }
    $ini=Join-Path $game 'OptiScaler.ini'; Put $ini ((Get-Content $ini -Raw).Replace('LoadAsiPlugins=true','LoadAsiPlugins=false'))
    Expect-Failure { Set-BundleFgMode $game XeMFG }
    Put $ini ((Get-Content $ini -Raw).Replace('LoadAsiPlugins=false','LoadAsiPlugins=auto'))
    Expect-Failure { Set-BundleFgMode $game XeMFG }
    Put $ini ((Get-Content $ini -Raw).Replace('LoadAsiPlugins=auto','LoadAsiPlugins=true'))
    Remove-Item (Join-Path $game 'OptiScaler/custom/Apex Neural Rendering FG/dlssg/kernels/pack.nrx')
    Expect-Failure { Get-BundleFgStatus $game }
    Write-Host 'FG coexist/switch tests passed.'
} finally { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
