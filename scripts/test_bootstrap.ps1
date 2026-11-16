# Entry-point tests with synthetic files; no GUI, network, archive extraction, or DLL loading.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'installer/Install.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$wanted=@('Test-Sha','Get-ReusableZip','Read-BundleLock','Get-BundleCache','Select-UpdateGame')
$definitions=$ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted },$false)
if ($definitions.Count -ne $wanted.Count) { throw 'Missing bootstrap functions.' }
foreach ($def in $definitions) { . ([scriptblock]::Create($def.Extent.Text)) }
function Get-Asset($asset,$kind,$path) {
    $script:fakeDownloads++
    [IO.File]::WriteAllText($path,'fixture asset bytes')
    if (-not (Test-Sha $path $asset.sha256)) { throw 'Test downloader SHA mismatch.' }
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('opti-bootstrap-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $assetPath=Join-Path $tmp 'source.zip'; [IO.File]::WriteAllText($assetPath,'fixture asset bytes')
    $asset=@{sha256=(Get-FileHash -LiteralPath $assetPath).Hash.ToLowerInvariant()}
    $script:fakeDownloads=0
    $path=Get-ReusableZip $asset 'Mochizuki' $tmp
    Assert ((Get-ReusableZip $asset 'Mochizuki' $tmp) -eq $path -and $script:fakeDownloads -eq 1) 'Verified download not reused.'
    [IO.File]::WriteAllText($path,'corrupt cache')
    Assert ((Get-ReusableZip $asset 'Mochizuki' $tmp) -eq $path -and $script:fakeDownloads -eq 2) 'Corrupt cache not checked.'
    $lockFile=Join-Path $tmp 'fixture.lock'
    $tag='bundle-20261116-01234567890123456789'
    [IO.File]::WriteAllText($lockFile,("{`"schema_version`":3,`"installer_edition`":1,`"release_tag`":`"$tag`"}"))
    $lock=Read-BundleLock $lockFile
    $dest=Join-Path $tmp $tag
    New-Item -ItemType Directory -Path $dest | Out-Null
    Set-Content -LiteralPath (Join-Path $dest '.bootstrap-ready') -Value (Get-FileHash -LiteralPath $lockFile).Hash -Encoding ASCII
    Assert ((Get-BundleCache $lock $lockFile $tmp) -eq $dest) 'Explicit lock argument not used, or validated cache not reused.'
    $exe=Join-Path $dest 'Game Demo.exe'; [IO.File]::WriteAllText($exe,'synthetic text')
    Assert ((Select-UpdateGame $exe) -eq $dest) 'Executable case/space path resolved incorrectly.'
    Assert ((Select-UpdateGame $dest) -eq $dest) 'Folder path resolved incorrectly.'
    Write-Host 'PASS: updater selection, explicit lock parameter, bundle cache, reused download, corrupt cache recovery.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
