# Download metadata only. All executable installer code remains local.
# Trust anchor: the fixed public repository over HTTPS, not a publisher signature.
function Get-BundleBytes([string]$Url, [int]$Limit, [bool]$AssetRedirects = $false) {
    $uri = [Uri]$Url
    for ($redirect = 0; $redirect -le 3; $redirect++) {
        $allowed = if ($redirect -eq 0) { @('api.github.com','github.com') } else { @('release-assets.githubusercontent.com','objects.githubusercontent.com') }
        if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Host -cnotin $allowed) {
            throw 'Update download destination is not allowed.'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.UserAgent = 'OptiScaler-Mochizuki-MetadataUpdater/1'
        $request.Accept = if ($uri.Host -ceq 'api.github.com') { 'application/vnd.github+json' } else { 'application/octet-stream' }
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $null; $stream = $null; $buffer = $null
        try {
            $response = $request.GetResponse()
            $code = [int]$response.StatusCode
            if ($code -in @(301,302,303,307,308)) {
                if (-not $AssetRedirects -or $redirect -eq 3 -or -not $response.Headers['Location']) { throw 'Unexpected update redirect.' }
                $uri = [Uri]::new($uri, $response.Headers['Location'])
                continue
            }
            if ($code -ne 200) { throw "Update download returned HTTP $code." }
            if ($response.ContentLength -gt $Limit) { throw 'Update metadata exceeds its size limit.' }
            $stream = $response.GetResponseStream()
            $buffer = [IO.MemoryStream]::new()
            $chunk = New-Object byte[] 8192
            while (($count = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
                if (($buffer.Length + $count) -gt $Limit) { throw 'Update metadata exceeds its size limit.' }
                $buffer.Write($chunk, 0, $count)
            }
            return ,$buffer.ToArray()
        } finally {
            if ($buffer) { $buffer.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
    throw 'Too many update redirects.'
}

function Get-BundleDigest([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Convert-BundleUtf8([byte[]]$Bytes) {
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    return $utf8.GetString($Bytes).TrimStart([char]0xFEFF)
}

function Get-LatestBundleLock([string]$Stage) {
    $repo = 'luxingzhi27/optiscaler-nightly-mochizuki'
    $api = "https://api.github.com/repos/$repo/releases/latest"
    $limits = @{ 'SHA256SUMS.txt'=16384; 'versions.lock.json'=65536 }
    $created = $null; $complete = $false
    try {
        if (-not [IO.Path]::IsPathRooted($Stage)) { throw 'Update staging directory must be absolute.' }
        $release = Convert-BundleUtf8 (Get-BundleBytes $api 1048576 $false) | ConvertFrom-Json
        $tag = [string]$release.tag_name
        if ($release.draft -ne $false -or $release.prerelease -ne $false -or $tag -cnotmatch '^bundle-[0-9]{8}-[a-f0-9]{20}$') {
            throw 'The latest release is not a supported stable bundle.'
        }
        $prefix = "https://github.com/$repo/releases/download/$tag/"
        $bytes = @{}
        foreach ($name in @('SHA256SUMS.txt','versions.lock.json')) {
            $assets = @($release.assets | Where-Object { $_.name -ceq $name })
            if ($assets.Count -ne 1) { throw "The release must contain exactly one $name." }
            $asset = $assets[0]
            if ([string]$asset.browser_download_url -cne ($prefix + $name) -or
                $asset.state -cne 'uploaded' -or $asset.size -lt 1 -or $asset.size -gt $limits[$name] -or
                [string]$asset.digest -cnotmatch '^sha256:[a-f0-9]{64}$') {
                throw "Invalid update asset metadata: $name."
            }
            [byte[]]$data = Get-BundleBytes ($prefix + $name) $limits[$name] $true
            if ($data.Length -ne $asset.size -or ('sha256:' + (Get-BundleDigest $data)) -cne $asset.digest) {
                throw "Update asset size or SHA-256 mismatch: $name."
            }
            $bytes[$name] = $data
        }
        $matching = @( (Convert-BundleUtf8 $bytes['SHA256SUMS.txt']) -split '\r?\n' | Where-Object { $_ -cmatch '^[a-f0-9]{64}  versions\.lock\.json$' } )
        if ($matching.Count -ne 1 -or $matching[0].Substring(0,64) -cne (Get-BundleDigest $bytes['versions.lock.json'])) {
            throw 'Release checksums do not identify the downloaded lock.'
        }
        $lock = Convert-BundleUtf8 $bytes['versions.lock.json'] | ConvertFrom-Json
        if ($lock.schema_version -ne 3 -or $lock.installer_edition -ne 1 -or [string]$lock.release_tag -cne $tag) {
            throw 'This bundle needs a different installer edition. Download its installer ZIP manually; the existing version was not changed.'
        }
        foreach ($key in @('optiscaler','mochizuki','mfgunlocker','optipatcher','openrr','anr')) {
            if ($null -eq $lock.$key -or [string]$lock.$key.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw "Missing locked component: $key." }
        }
        if ($null -ne $lock.cjk -and [string]$lock.cjk.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid CJK lock.' }
        # Only a fresh private staging child is written; no live lock/cache is replaced.
        New-Item -ItemType Directory -Force -Path $Stage | Out-Null
        $created = Join-Path $Stage ('latest-lock-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $created | Out-Null
        $path = Join-Path $created 'versions.lock.json'
        [IO.File]::WriteAllBytes($path, $bytes['versions.lock.json'])
        $complete = $true
        return $path
    } catch {
        throw ('Could not prepare the latest bundle; the installed version was not changed. ' + $_.Exception.Message)
    } finally {
        if (-not $complete -and $created -and (Test-Path -LiteralPath $created)) {
            Remove-Item -LiteralPath $created -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
