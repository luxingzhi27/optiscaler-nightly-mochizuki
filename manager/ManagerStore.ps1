# Local-only manager registry. DLL bytes never leave this computer.
function Assert-ManagerPlainPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not supported: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
}
function Get-ManagerRoot([string]$Root) {
    if (-not $Root) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable. Supply a manager storage folder.' }
        $Root = Join-Path $env:LOCALAPPDATA 'OptiScaler-Mochizuki/Manager'
    }
    if (-not [IO.Path]::IsPathRooted($Root)) { throw 'The manager storage folder must be an absolute path.' }
    $Root = [IO.Path]::GetFullPath($Root)
    Assert-ManagerPlainPath $Root
    return $Root
}
function Read-ManagerStore([string]$Root) {
    $path = Join-Path $Root 'registry.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{schema_version=1;games=@();dlls=@();defaults=[pscustomobject]@{NR=$null;RR=$null}}
    }
    Assert-ManagerPlainPath $path
    try { $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Manager registry cannot be read. The existing registry was not replaced.' }
    if ($state.schema_version -ne 1 -or $null -eq $state.games -or $null -eq $state.dlls -or $null -eq $state.defaults) { throw 'Unsupported or damaged manager registry; no changes made.' }
    return $state
}
function Write-ManagerStore([string]$Root, $State) {
    $path = Join-Path $Root 'registry.json'; Assert-ManagerPlainPath $path
    $tmp = Join-Path $Root ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($State | ConvertTo-Json -Depth 12))
        $stream = [IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($path)) { $backup = $tmp + '.bak'; [IO.File]::Replace($tmp,$path,$backup); [IO.File]::Delete($backup) } else { [IO.File]::Move($tmp,$path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Invoke-ManagerStoreWrite([string]$Root,[scriptblock]$Action) {
    $Root = Get-ManagerRoot $Root
    [void][IO.Directory]::CreateDirectory($Root)
    $lockPath = Join-Path $Root 'registry.lock'; Assert-ManagerPlainPath $lockPath
    try { $guard = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { throw 'Manager storage is busy or unavailable. Close the other manager and retry.' }
    try { & $Action $Root (Read-ManagerStore $Root) } finally { $guard.Dispose() }
}
function Get-ManagerGames([string]$Root) {
    $state = Read-ManagerStore (Get-ManagerRoot $Root)
    return @($state.games)
}
function Register-ManagerGame([Parameter(Mandatory=$true)][string]$ExePath,[string]$Root) {
    if (-not [IO.Path]::IsPathRooted($ExePath)) { throw 'Select an absolute game executable path.' }
    Assert-ManagerPlainPath $ExePath
    $file = Get-Item -LiteralPath $ExePath -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -ine '.exe') { throw 'Select an existing game .exe file.' }
    $canonical = [IO.Path]::GetFullPath($file.FullName)
    Invoke-ManagerStoreWrite $Root {
        param($storeRoot,$state)
        $existing = @($state.games | Where-Object { [string]::Equals($_.exe_path,$canonical,[StringComparison]::OrdinalIgnoreCase) })
        if ($existing.Count) { return $existing[0] }
        $record = [pscustomobject]@{id=[guid]::NewGuid().ToString('N');exe_path=$canonical;game_dir=$file.DirectoryName;name=$file.BaseName}
        $state.games = @($state.games) + @($record)
        Write-ManagerStore $storeRoot $state
        return $record
    }
}
function Get-ManagerFileVersion([string]$Path) {
    $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return ('{0}.{1}.{2}.{3}' -f $v.FileMajorPart,$v.FileMinorPart,$v.FileBuildPart,$v.FilePrivatePart)
}
function Assert-ManagerDll([ValidateSet('NR','RR')][string]$Kind,[string]$Path) {
    $expected = if ($Kind -eq 'NR') { 'nvngx_dlssnr.dll' } else { 'nvngx_dlssd.dll' }
    if ([IO.Path]::GetFileName($Path) -ine $expected -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Select $expected for $Kind." }
    Assert-ManagerPlainPath $Path
    $s = [IO.File]::OpenRead($Path); $r = New-Object IO.BinaryReader($s)
    try {
        if ($s.Length -lt 256 -or $r.ReadUInt16() -ne 0x5a4d) { throw 'DLL is not a PE image.' }
        $s.Position = 60; $pe = $r.ReadUInt32()
        if ($pe -lt 64 -or $pe -gt ($s.Length - 26)) { throw 'DLL has an invalid PE header.' }
        $s.Position = $pe
        if ($r.ReadUInt32() -ne 0x4550 -or $r.ReadUInt16() -ne 0x8664) { throw 'DLL must be a Windows x64 PE image.' }
        $s.Position = $pe + 22
        if (($r.ReadUInt16() -band 0x2000) -eq 0 -or $r.ReadUInt16() -ne 0x20b) { throw 'DLL must be a PE32+ x64 dynamic library.' }
    } finally { $r.Dispose(); $s.Dispose() }
    $version = Get-ManagerFileVersion $Path
    $allowed = if ($Kind -eq 'NR') { @('310.9.16.0','310.8.0.0') } else { @('310.9.1.0') }
    if ($version -notin $allowed) { throw "Unsupported $Kind DLL version $version. Required: $($allowed -join ', ')." }
    return $version
}
function Get-ManagerCachedDll([string]$Root,$Record) {
    if ($Record.kind -cnotin @('NR','RR') -or $Record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Record.version -notmatch '^310\.(9\.16|8\.0|9\.1)\.0$') { throw 'Invalid DLL registry record.' }
    $name = if ($Record.kind -eq 'NR') { 'nvngx_dlssnr.dll' } else { 'nvngx_dlssd.dll' }
    $path = Join-Path $Root "dlls/$($Record.kind)/$($Record.version)/$($Record.sha256)/$name"
    if ($Record.id -cne "$($Record.kind):$($Record.sha256)" -or $Record.file_name -cne $name -or -not [string]::Equals($Record.path,$path,[StringComparison]::OrdinalIgnoreCase)) { throw 'DLL registry path is invalid.' }
    $version = Assert-ManagerDll $Record.kind $path
    if ($version -ne $Record.version -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Record.sha256) { throw 'Cached DLL verification failed. Import your original DLL again.' }
    return $Record
}
function Add-ManagerDll([Parameter(Mandatory=$true)][ValidateSet('NR','RR')][string]$Kind,[Parameter(Mandatory=$true)][string]$Path,[switch]$SetDefault,[string]$Root) {
    $Kind = $Kind.ToUpperInvariant()
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Select an absolute DLL path.' }
    [void](Assert-ManagerDll $Kind $Path)
    Invoke-ManagerStoreWrite $Root {
        param($storeRoot,$state)
        $stage = Join-Path $storeRoot ('.import-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($stage)
        try {
            $name = if ($Kind -eq 'NR') { 'nvngx_dlssnr.dll' } else { 'nvngx_dlssd.dll' }
            $copy = Join-Path $stage $name
            [IO.File]::Copy($Path,$copy,$false)
            $version = Assert-ManagerDll $Kind $copy
            $sha = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant()
            $id = "${Kind}:$sha"; $folder = Join-Path $storeRoot "dlls/$Kind/$version/$sha"
            $dest = Join-Path $folder $name; Assert-ManagerPlainPath $dest
            if (Test-Path -LiteralPath $dest) {
                if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha) {
                    # Preserve the damaged bytes while atomically installing the verified staged copy.
                    $quarantine = Join-Path $storeRoot ("quarantine/$Kind/$version/$sha/" + [guid]::NewGuid().ToString('N'))
                    Assert-ManagerPlainPath $quarantine
                    [void][IO.Directory]::CreateDirectory($quarantine)
                    $backup = Join-Path $quarantine ($name + '.corrupt')
                    [IO.File]::Replace($copy,$dest,$backup)
                }
            } else {
                [void][IO.Directory]::CreateDirectory($folder)
                [IO.File]::Move($copy,$dest)
            }
            $record = [pscustomobject]@{id=$id;kind=$Kind;version=$version;sha256=$sha;path=$dest;file_name=$name}
            $state.dlls = @($state.dlls | Where-Object { $_.id -cne $id }) + @($record)
            if ($SetDefault) { $state.defaults.$Kind = $id }
            Write-ManagerStore $storeRoot $state
            return $record
        } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
    }
}
function Get-ManagerDlls([ValidateSet('NR','RR')][string]$Kind,[string]$Root) {
    $state = Read-ManagerStore (Get-ManagerRoot $Root)
    return @($state.dlls | Where-Object { -not $Kind -or $_.kind -eq $Kind })
}
function Set-ManagerDefaultDll([Parameter(Mandatory=$true)][ValidateSet('NR','RR')][string]$Kind,[Parameter(Mandatory=$true)][string]$Id,[string]$Root) {
    $Kind = $Kind.ToUpperInvariant()
    Invoke-ManagerStoreWrite $Root {
        param($storeRoot,$state)
        $matches = @($state.dlls | Where-Object { $_.id -ceq $Id -and $_.kind -ceq $Kind })
        if ($matches.Count -ne 1) { throw 'Select an imported DLL of the matching type.' }
        $record = Get-ManagerCachedDll $storeRoot $matches[0]
        $state.defaults.$Kind = $Id
        Write-ManagerStore $storeRoot $state
        return $record
    }
}
function Get-ManagerDefaultDll([Parameter(Mandatory=$true)][ValidateSet('NR','RR')][string]$Kind,[string]$Root) {
    $Root = Get-ManagerRoot $Root; $state = Read-ManagerStore $Root
    $id = $state.defaults.$Kind
    if (-not $id) { return $null }
    $matches = @($state.dlls | Where-Object { $_.id -ceq $id -and $_.kind -eq $Kind })
    if ($matches.Count -ne 1) { throw 'Default DLL record is missing or ambiguous. Select a DLL again.' }
    return Get-ManagerCachedDll $Root $matches[0]
}
