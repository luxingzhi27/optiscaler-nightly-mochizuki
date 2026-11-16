# Synthetic metadata only; downloads are mocked and no executable payload runs.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'installer/LatestBundle.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | Format-List; throw 'LatestBundle.ps1 parse failed.' }
. (Join-Path $root 'installer/LatestBundle.ps1')
function Assert($Test, [string]$Message) { if (-not $Test) { throw $Message } }
function Expect-Failure([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed 'Expected update to fail closed.'
}
$utf8 = [Text.UTF8Encoding]::new($false)
$repo = 'luxingzhi27/optiscaler-nightly-mochizuki'
$api = "https://api.github.com/repos/$repo/releases/latest"
$tag = 'bundle-20261116-' + ('a' * 20)
$prefix = "https://github.com/$repo/releases/download/$tag/"
function New-Fixture([string]$Scenario) {
    $lock = @{schema_version=3; installer_edition=1; release_tag=$tag; cjk=$null}
    foreach ($key in @('optiscaler','mochizuki','mfgunlocker','optipatcher','openrr','anr')) { $lock[$key]=@{sha256=('a'*64)} }
    if ($Scenario -eq 'edition') { $lock.installer_edition=2 }
    if ($Scenario -eq 'schema') { $lock.schema_version=4 }
    if ($Scenario -eq 'lock-tag') { $lock.release_tag='bundle-20261115-' + ('b'*20) }
    if ($Scenario -eq 'missing-component') { $lock.Remove('anr') }
    $lockBytes = $utf8.GetBytes(($lock | ConvertTo-Json -Depth 10 -Compress))
    $sum = (Get-BundleDigest $lockBytes) + "  versions.lock.json`n"
    if ($Scenario -eq 'checksums') { $sum = ('b'*64) + "  versions.lock.json`n" }
    if ($Scenario -eq 'duplicate-checksum') { $sum += $sum }
    $sumBytes = $utf8.GetBytes($sum)
    $script:fixtures = @{}
    $script:fixtures[$prefix + 'versions.lock.json'] = $lockBytes
    $script:fixtures[$prefix + 'SHA256SUMS.txt'] = $sumBytes
    $assets = @()
    foreach ($name in @('versions.lock.json','SHA256SUMS.txt')) {
        $bytes = $script:fixtures[$prefix + $name]
        $assets += @{name=$name; state='uploaded'; browser_download_url=($prefix+$name); size=$bytes.Length; digest=('sha256:' + (Get-BundleDigest $bytes))}
    }
    if ($Scenario -eq 'url') { $assets[0].browser_download_url='https://evil.invalid/versions.lock.json' }
    if ($Scenario -eq 'size') { $assets[0].size=10000000 }
    if ($Scenario -eq 'digest') { $assets[0].digest='sha256:' + ('b'*64) }
    if ($Scenario -eq 'duplicate-asset') { $assets += $assets[0] }
    $release = @{tag_name=$tag; draft=$false; prerelease=$false; assets=$assets}
    if ($Scenario -eq 'draft') { $release.draft=$true }
    if ($Scenario -eq 'tag') { $release.tag_name='../../invalid' }
    $script:fixtures[$api] = $utf8.GetBytes(($release | ConvertTo-Json -Depth 10 -Compress))
    $script:requested = @()
    $script:networkFail = $Scenario -eq 'network'
}
function Get-BundleBytes([string]$Url, [int]$Limit, [bool]$AssetRedirects=$false) {
    $script:requested += $Url
    if ($script:networkFail) { throw 'Synthetic network error.' }
    if (-not $script:fixtures.ContainsKey($Url)) { throw 'Unapproved synthetic request.' }
    [byte[]]$bytes = $script:fixtures[$Url]
    Assert ($bytes.Length -le $Limit) 'Synthetic payload exceeds request bound.'
    return ,$bytes
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('bundle-latest-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $old = Join-Path $tmp 'versions.lock.json'
    [IO.File]::WriteAllText($old, 'existing-installed-version')
    New-Fixture 'valid'
    $result = @(Get-LatestBundleLock $tmp)
    Assert ($result.Count -eq 1) 'Updater emitted more than the lock path.'
    Assert (Test-Path -LiteralPath $result[0] -PathType Leaf) 'Validated lock missing.'
    Assert ($result[0] -ne $old) 'Updater overwrote an existing lock.'
    Assert ($script:requested.Count -eq 3) 'Updater requested unexpected files.'
    Assert (-not ($script:requested | Where-Object { $_ -match '\.(?:zip|ps1|cmd)$' })) 'Updater fetched code.'
    foreach ($scenario in @('edition','schema','lock-tag','missing-component','checksums','duplicate-checksum','url','size','digest','duplicate-asset','draft','tag','network')) {
        New-Fixture $scenario
        Expect-Failure { Get-LatestBundleLock $tmp }
        Assert (([IO.File]::ReadAllText($old)) -ceq 'existing-installed-version') "Existing version changed: $scenario"
    }
    New-Fixture 'valid'
    Expect-Failure { Get-LatestBundleLock 'relative-stage' }
    Assert ($script:requested.Count -eq 0) 'Relative stage made a request.'
    Write-Host 'Latest-lock metadata checks passed; no downloaded code executed.'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
