# Offline synthetic fixtures only. No upstream binary is loaded or executed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Install.ps1','OptionalProfiles.ps1','Restore.ps1')) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root "installer/$name"), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { $errors | Format-List; throw "PowerShell syntax error: $name" }
}
. (Join-Path $root 'installer/OptionalProfiles.ps1')
function Assert($Value, $Message) { if (-not $Value) { throw $Message } }
function Expect-Failure([scriptblock]$Action) { $failed=$false; try { & $Action } catch { $failed=$true }; Assert $failed 'Expected fail-closed behavior.' }
function Put([string]$Path, [string]$Text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null; [IO.File]::WriteAllText($Path,$Text) }
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('bundle-profile-tests-' + [guid]::NewGuid().ToString('N'))
try {
    $game=Join-Path $tmp 'game'; $payload=Join-Path $tmp 'payload'
    New-Item -ItemType Directory -Force -Path (Join-Path $game 'OptiScaler/plugins') | Out-Null
    $original="[Menu]`r`nFGInput=keep`r`n[Plugins]`r`nLoadAsiPlugins=true`r`n[FrameGen]`r`nFGInput=upscaler`r`nFGOutput=xefg`r`nFGNvngxReplacement=auto`r`nDisableHudless=true`r`n"
    Put (Join-Path $game 'OptiScaler.ini') $original
    Put (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi') 'fake MFG DLL: never executed'
    Put (Join-Path $payload 'anr/Apex Neural Rendering FG/dlssg/nvngx_dlssg.dll') 'fake ANR DLL: never executed'
    Put (Join-Path $payload 'anr/Apex Neural Rendering FG/dlssg/nr_fg.ini') 'max_generated=5'
    Expect-Failure { Get-ProfilePath $game '../escape' }
    Expect-Failure { Get-ProfilePath $game 'x/../escape' }
    Expect-Failure { Get-ProfilePath $game 'x:escape' }
    Expect-Failure { Set-ProfileIni "[FrameGen]`nFGInput=one`nFGInput=two" 'FrameGen' 'FGInput' 'new' }
    Expect-Failure { Assert-RrModel (Join-Path $tmp 'missing/nvngx_dlssd.dll') }
    $backup=Apply-OptionalProfile $game $payload 'anr' $null
    $ini=Get-Content -LiteralPath (Join-Path $game 'OptiScaler.ini') -Raw
    Assert ($ini.Contains("[Menu]`r`nFGInput=keep")) 'Unrelated section changed.'
    Assert ($ini.Contains('FGNvngxReplacement=Apex Neural Rendering FG')) 'ANR not selected.'
    Assert ($ini.Contains('FGOutput=nofg')) 'Conflicting FG output retained.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi'))) 'MFG stayed active.'
    Assert (Test-Path -LiteralPath (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi.disabled-anr')) 'MFG not preserved.'
    Put (Join-Path $game 'OptiScaler.ini') ($ini + '; later edit')
    Expect-Failure { Restore-OptionalProfile $game $backup }
    Put (Join-Path $game 'OptiScaler.ini') $ini
    Restore-OptionalProfile $game $backup
    Assert ((Get-Content -LiteralPath (Join-Path $game 'OptiScaler.ini') -Raw) -ceq $original) 'Restore not byte-equivalent.'
    Assert (Test-Path -LiteralPath (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi')) 'MFG not restored.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler/custom/Apex Neural Rendering FG/dlssg/nvngx_dlssg.dll'))) 'ANR not removed during restore.'

    # Selective OpenRR extraction from backslash-containing ZIP; forbidden files never staged.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=Join-Path $tmp 'launcher.zip'
    $zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @('OptiScaler\plugins\openrr-amd.asi','openrr-amd.ini','openrr-amd\shaders\a.spv','openrr-amd\shaders-gfx11\a.spv','openrr-ngx-host.dll','nvngx_dlssd.dll','Licenses\OpenRR_MIT.txt','Licenses\OpenRR_THIRD_PARTY.md')) {
            $entry=$zip.CreateEntry($name); $writer=[IO.StreamWriter]::new($entry.Open()); $writer.Write('fixture'); $writer.Dispose()
        }
    } finally { $zip.Dispose() }
    $rr=Join-Path $payload 'openrr'
    Expand-ProfileZip $archive $rr 'openrr'
    Assert (Test-Path -LiteralPath (Join-Path $rr 'openrr-amd.asi')) 'OpenRR not staged.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $rr 'nvngx_dlssd.dll'))) 'NVIDIA DLL was extracted.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $rr 'openrr-ngx-host.dll'))) 'Host DLL was extracted.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $rr 'openrr-amd/shaders-gfx11'))) 'Unselected GPU shaders were extracted.'
    Put (Join-Path $rr 'openrr-amd.ini') "[OpenRR]`nOptiFGHost=true"
    $model=Join-Path $tmp 'nvngx_dlssd.dll'; Put $model 'synthetic local model'
    Expect-Failure { Assert-RrModel $model }
    # Version checker was independently rejection-tested. Stub it only for synthetic copy/rollback test.
    function Assert-RrModel([string]$Path) { if ($Path -ne $model) { throw 'Unexpected model test path' } }
    $backup=Apply-OptionalProfile $game $payload 'openrr' $model
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $game 'openrr-amd.ini')).Contains('OptiFGHost=false')) 'Host mode enabled.'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $game 'openrr-amd/nvngx_dlssd.dll')) -ceq 'synthetic local model') 'Local RR model not copied.'
    Assert (Test-Path -LiteralPath (Join-Path $game 'OptiScaler/plugins/MFGUnlocker.asi')) 'OpenRR-only changed FG provider.'
    Restore-OptionalProfile $game $backup
    Assert (-not (Test-Path -LiteralPath (Join-Path $game 'openrr-amd/nvngx_dlssd.dll'))) 'Local model not restored.'
    Write-Host 'PASS: syntax, safe paths, duplicate INI rejection, ANR profile, MFG preservation, restore/edit guard, selective OpenRR extraction, model rejection, standalone host default.'
} finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
