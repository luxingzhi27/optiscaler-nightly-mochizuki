$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'manager/ManagerStore.ps1'
$tokens=$null; $errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. $source
function Check($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Refuses([scriptblock]$Action) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed 'Expected refusal.' }
function Put([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllText($Path,$Text) }
function Put-Pe([string]$Path,[byte]$Marker=1) {
    $bytes=New-Object byte[] 512
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[60]=0x80
    $bytes[128]=0x50; $bytes[129]=0x45; $bytes[132]=0x64; $bytes[133]=0x86
    $bytes[151]=0x20; $bytes[152]=0x0b; $bytes[153]=0x02; $bytes[500]=$Marker
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllBytes($Path,$bytes)
}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('manager-store-'+[guid]::NewGuid().ToString('N'))
$realVersionFunction = ${function:Get-ManagerFileVersion}
try {
    $store=Join-Path $tmp 'Store'; $game=Join-Path $tmp 'Game'; $exe=Join-Path $game 'game.exe'
    Put $exe 'original executable'; Put (Join-Path $game 'settings.ini') 'unchanged'
    $before=@(Get-ChildItem -LiteralPath $game -Recurse | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ','
    Check (@(Get-ManagerGames -Root $store).Count -eq 0) 'Empty store not empty.'
    $g=Register-ManagerGame -ExePath $exe -Root $store
    $again=Register-ManagerGame -ExePath (Join-Path $game './game.exe') -Root $store
    Check ($g.id -eq $again.id -and @(Get-ManagerGames -Root $store).Count -eq 1) 'Canonical registration did not deduplicate.'
    $after=@(Get-ChildItem -LiteralPath $game -Recurse | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ','
    Check ($before -eq $after) 'Registration changed game files.'
    Refuses { Register-ManagerGame -ExePath (Join-Path $game 'settings.ini') -Root $store }
    Refuses { Register-ManagerGame -ExePath 'relative.exe' -Root $store }
    Check ($null -eq (Get-ManagerDefaultDll NR -Root $store)) 'Unexpected default.'
    $nr=Join-Path $tmp 'Source/nvngx_dlssnr.dll'; $rr=Join-Path $tmp 'Source/nvngx_dlssd.dll'; Put-Pe $nr; Put-Pe $rr 2
    # Synthetic PE images intentionally have no resources. Production version reader rejects them.
    Refuses { Add-ManagerDll NR $nr -Root $store }
    # Only version-resource reader is stubbed; PE, hashing, persistence and cache checks remain real.
    function Get-ManagerFileVersion([string]$Path) { if ([IO.Path]::GetFileName($Path) -eq 'nvngx_dlssd.dll') { '310.9.1.0' } else { '310.9.16.0' } }
    $a=Add-ManagerDll NR $nr -SetDefault -Root $store
    $b=Add-ManagerDll RR $rr -SetDefault -Root $store
    Check ($a.path -ne $nr -and $b.path -ne $rr) 'Original paths retained instead of cached paths.'
    Check ($a.path.Contains($a.sha256) -and $a.path.Contains($a.version)) 'Not content-addressed.'
    [void](Add-ManagerDll NR $nr -Root $store)
    Check (@(Get-ManagerDlls -Root $store).Count -eq 2) 'DLL import did not deduplicate.'
    $older=Join-Path $tmp 'Older/nvngx_dlssnr.dll'; Put-Pe $older 3
    function Get-ManagerFileVersion([string]$Path) { '310.8.0.0' }
    $old=Add-ManagerDll NR $older -Root $store
    Check ($old.version -eq '310.8.0.0') 'Supported older NR version rejected.'
    function Get-ManagerFileVersion([string]$Path) { if ([IO.Path]::GetFileName($Path) -eq 'nvngx_dlssd.dll') { '310.9.1.0' } else { '310.9.16.0' } }
    Check (@(Get-ManagerDlls NR -Root $store).Count -eq 2) 'NR type filtering failed.'
    Remove-Item -LiteralPath $nr,$rr
    Check ((Get-ManagerDefaultDll NR -Root $store).sha256 -eq $a.sha256) 'Moved source broke default.'
    Check ((Get-ManagerDefaultDll RR -Root $store).sha256 -eq $b.sha256) 'RR default wrong.'
    Refuses { Set-ManagerDefaultDll NR $b.id -Root $store }
    [void](Set-ManagerDefaultDll NR $a.id -Root $store)
    $registry=Join-Path $store 'registry.json'; $saved=[IO.File]::ReadAllText($registry)
    $bad=Join-Path $tmp 'Bad/nvngx_dlssnr.dll'; Put-Pe $bad
    $bytes=[IO.File]::ReadAllBytes($bad); $bytes[132]=0x4c; $bytes[133]=1; [IO.File]::WriteAllBytes($bad,$bytes)
    Refuses { Add-ManagerDll NR $bad -SetDefault -Root $store }
    Check ([IO.File]::ReadAllText($registry) -eq $saved) 'Rejected import changed registry.'
    Put-Pe $bad; function Get-ManagerFileVersion([string]$Path) { '310.9.99.0' }
    Refuses { Add-ManagerDll NR $bad -Root $store }
    function Get-ManagerFileVersion([string]$Path) { if ([IO.Path]::GetFileName($Path) -eq 'nvngx_dlssd.dll') { '310.9.1.0' } else { '310.9.16.0' } }
    $wrong=Join-Path $tmp 'Bad/nvngx_dlss.dll'; Put-Pe $wrong
    Refuses { Add-ManagerDll NR $wrong -Root $store }
    $lock=[IO.File]::Open((Join-Path $store 'registry.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Refuses { Set-ManagerDefaultDll NR $a.id -Root $store } } finally { $lock.Dispose() }
    Check ([IO.File]::ReadAllText($registry) -eq $saved) 'Busy registry was changed.'
    $bytes=[IO.File]::ReadAllBytes($a.path); $bytes[500]=99; [IO.File]::WriteAllBytes($a.path,$bytes)
    Refuses { Get-ManagerDefaultDll NR -Root $store }
    Check ((Get-ManagerDefaultDll RR -Root $store).id -eq $b.id) 'NR corruption affected RR.'
    $corruptHash=(Get-FileHash -LiteralPath $a.path).Hash
    # Re-create the original source after it was moved away and repair the cached identity.
    Put-Pe $nr
    $repaired=Add-ManagerDll NR $nr -Root $store
    Check ($repaired.id -eq $a.id -and $repaired.path -eq $a.path) 'Repair changed cached identity.'
    Check ((Get-ManagerDefaultDll NR -Root $store).sha256 -eq $a.sha256) 'Re-import did not repair the default.'
    $quarantined=@(Get-ChildItem -LiteralPath (Join-Path $store 'quarantine') -Recurse -File)
    Check ($quarantined.Count -eq 1) 'Corrupt cached bytes were not quarantined exactly once.'
    Check ((Get-FileHash -LiteralPath $quarantined[0].FullName).Hash -eq $corruptHash) 'Quarantine did not preserve damaged bytes.'
    Check (@(Get-ManagerDlls NR -Root $store).Count -eq 2) 'Repair duplicated the registry entry.'
    [void](Add-ManagerDll NR $nr -Root $store)
    Check (@(Get-ChildItem -LiteralPath (Join-Path $store 'quarantine') -Recurse -File).Count -eq 1) 'Healthy re-import created another quarantine.'
    Check ((Get-ManagerDefaultDll RR -Root $store).id -eq $b.id) 'NR repair changed RR default.'
    [IO.File]::WriteAllText($registry,'broken json')
    Refuses { Register-ManagerGame -ExePath $exe -Root $store }
    Check ([IO.File]::ReadAllText($registry) -eq 'broken json') 'Damaged registry silently reset.'
    Check (@(Get-ChildItem -LiteralPath $store -Filter '*.tmp').Count -eq 0) 'Atomic save leaked temporary files.'
    Write-Host 'Manager store tests passed (synthetic PE headers; version reader mocked after rejection test).'
} finally {
    ${function:Get-ManagerFileVersion}=$realVersionFunction
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
