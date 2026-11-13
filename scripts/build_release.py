#!/usr/bin/env python3
"""Build a small, version-locked installer; never execute upstream binaries."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
GH = 'https://api.github.com'
UPSTREAM = 'OptiScaler/OptiScaler-nightly'
GL = 'https://gitlab.com/api/v4/projects/88319462'
MAX_DOWNLOAD = 1500 * 1024 * 1024
MAX_EXPANDED = 4 * 1024 ** 3
TAG = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$')


def request(url, *, api=False):
    headers = {'User-Agent': 'OptiScaler-Mochizuki-Release-Builder/1.0'}
    if api and urllib.parse.urlparse(url).netloc == 'api.github.com':
        headers['Accept'] = 'application/vnd.github+json'
        token = os.environ.get('GH_TOKEN', '')
        if token:
            headers['Authorization'] = 'Bearer ' + token
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120)


def api(url):
    with request(url, api=True) as response:
        return json.load(response)


def valid_url(url, family):
    patterns = {
        'opti': r'https://github\.com/[Oo]pti[Ss]caler/OptiScaler-nightly/releases/download/nightly-[0-9]{8}/OptiScaler_[A-Za-z0-9._-]+\.7z',
        'mochi': r'https://gitlab\.com/(?:api/v4/projects/88319462/packages/generic/dlssnr-amd/[0-9.]+|mochizuki0323/DLSSNR-AMD/-/releases/v[0-9.]+/downloads)/DLSSNR-AMD-Vulkan-Windows-[0-9.]+-preview-x86_64\.zip',
        'cjk': r'https://gitlab\.com/(?:api/v4/projects/88319462/packages/generic/dlssnr-amd/[0-9.]+|mochizuki0323/DLSSNR-AMD/-/releases/v[0-9.]+/downloads)/DLSSNR-AMD-lang-CJK-[0-9.]+\.zip',
    }
    if not re.fullmatch(patterns[family], url):
        raise ValueError('Unexpected upstream URL/layout; manual review required: ' + url)
    return url


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def download(url, path):
    with request(url) as response, path.open('wb') as out:
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > MAX_DOWNLOAD:
                raise ValueError('Upstream asset exceeds download limit')
            out.write(chunk)
    return sha(path)


def safe_name(name, seen):
    p = PurePosixPath(name)
    if not name or p.is_absolute() or '..' in p.parts or '\\' in name or ':' in name or '\x00' in name:
        raise ValueError('Unsafe archive path')
    norm = str(p).lower()
    if norm in seen:
        raise ValueError('Duplicate archive path: ' + name)
    seen.add(norm)


def read_zip(path, needed):
    seen, result = set(), {}
    with zipfile.ZipFile(path) as z:
        if sum(i.file_size for i in z.infolist()) > MAX_EXPANDED:
            raise ValueError('Expanded ZIP too large')
        for i in z.infolist():
            safe_name(i.filename.rstrip('/'), seen)
            mode = (i.external_attr >> 16) & 0o170000
            if mode not in (0, 0o100000, 0o040000):
                raise ValueError('Non-regular ZIP entry')
            if i.filename in needed:
                if i.file_size > 4 * 1024 * 1024:
                    raise ValueError('Unexpectedly large metadata entry')
                result[i.filename] = z.read(i)
        bad = z.testzip()
        if bad:
            raise ValueError('ZIP CRC failed: ' + bad)
    return seen, result


def read_7z(path, needed):
    """Use runner's libarchive; no downloaded executable or archive script runs."""
    c = ctypes
    lib = c.CDLL('libarchive.so.13')
    def bind(name, result, *args):
        f = getattr(lib, name); f.restype = result; f.argtypes = args; return f
    ptr = c.c_void_p
    new = bind('archive_read_new', ptr)
    fmt = bind('archive_read_support_format_7zip', c.c_int, ptr)
    op = bind('archive_read_open_filename', c.c_int, ptr, c.c_char_p, c.c_size_t)
    nxt = bind('archive_read_next_header', c.c_int, ptr, c.POINTER(ptr))
    name = bind('archive_entry_pathname', c.c_char_p, ptr)
    mode = bind('archive_entry_filetype', c.c_uint, ptr)
    size = bind('archive_entry_size', c.c_longlong, ptr)
    read = bind('archive_read_data', c.c_ssize_t, ptr, ptr, c.c_size_t)
    free = bind('archive_read_free', c.c_int, ptr)
    err = bind('archive_error_string', c.c_char_p, ptr)
    archive = new()
    def check(code):
        if code < 0:
            raise ValueError((err(archive) or b'Archive error').decode(errors='replace'))
    seen, result, expanded = set(), {}, 0
    try:
        check(fmt(archive)); check(op(archive, os.fsencode(path), 10240))
        entry = ptr(); buf = c.create_string_buffer(1024 * 1024)
        while (rc := nxt(archive, c.byref(entry))) != 1:
            check(rc)
            n = name(entry).decode('utf-8'); safe_name(n.rstrip('/'), seen)
            if mode(entry) not in (0o100000, 0o040000):
                raise ValueError('Non-regular 7z entry')
            expanded += max(0, size(entry))
            if expanded > MAX_EXPANDED:
                raise ValueError('Expanded 7z too large')
            if n in needed:
                chunks = []
                if size(entry) > 4 * 1024 * 1024:
                    raise ValueError('Unexpectedly large metadata entry')
                while (count := read(archive, buf, len(buf))) != 0:
                    check(count); chunks.append(buf.raw[:count])
                result[n] = b''.join(chunks)
    finally:
        free(archive)
    return seen, result


def check_layout(mochi, opti, cjk=None):
    m, meta = read_zip(mochi, {'install.ps1'})
    required_m = {'install.bat', 'install.ps1', 'optiscaler/asi/dlssnr-amd.asi', 'optiscaler/asi/nr_present_probe.exe', 'ini/dlssnr-amd-optiscaler.ini', 'ini/dlssnr-amd-optiscaler-renodx.ini', 'model-tools/dlssnr_extract_model.exe'}
    if not required_m <= m or not any(n.startswith('dlssnr-amd/shaders/') for n in m):
        raise ValueError('Mochizuki package layout changed; manual review required')
    text = meta['install.ps1'].decode('utf-8-sig')
    o, ometa = read_7z(opti, {'OptiScaler.ini'})
    if not {'optiscaler.dll', 'optiscaler.ini', 'setup_windows.bat'} <= o or not any(n.startswith('optiscaler/') for n in o) or not any(n.startswith('licenses/') for n in o):
        raise ValueError('OptiScaler package layout changed')
    import configparser
    config = configparser.ConfigParser(strict=False, interpolation=None)
    config.read_string(ometa['OptiScaler.ini'].decode('utf-8-sig'))
    for section, key in [('Plugins', 'LoadAsiPlugins'), ('Log', 'LogToFile'), ('Log', 'LogLevel'), ('Menu', 'FGShortcutKey')]:
        if not config.has_option(section, key) or f"'{section}|{key}'" not in text:
            raise ValueError('Installer/INI contract changed: ' + section + '.' + key)
    if cjk:
        names, _ = read_zip(cjk, set())
        if 'lang/zh-cn.txt' not in names or not all(n.startswith('lang/') for n in names):
            raise ValueError('CJK archive layout changed')


def find_releases():
    entries = api(f'{GH}/repos/{UPSTREAM}/releases?per_page=20')
    candidates = [r for r in entries if not r['draft'] and re.fullmatch(r'nightly-\d{8}', r['tag_name'])]
    if not candidates:
        raise ValueError('No nightly release found')
    opti = max(candidates, key=lambda r: (r['published_at'], r['tag_name']))
    assets = [a for a in opti['assets'] if re.fullmatch(r'OptiScaler_[A-Za-z0-9._-]+\.7z', a['name'])]
    if len(assets) != 1:
        raise ValueError('Expected one OptiScaler 7z')
    asset = assets[0]
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', digest):
        raise ValueError('GitHub asset SHA256 missing; refuse unverified release')
    mochi = api(GL + '/releases/permalink/latest')
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', mochi['tag_name']):
        raise ValueError('Invalid Mochizuki tag')
    links = mochi['assets']['links']
    windows = [a for a in links if re.fullmatch(r'DLSSNR-AMD-Vulkan-Windows-[A-Za-z0-9._-]+-x86_64\.zip', a['name'])]
    language = [a for a in links if re.fullmatch(r'DLSSNR-AMD-lang-CJK-[A-Za-z0-9._-]+\.zip', a['name'])]
    if len(windows) != 1 or len(language) > 1:
        raise ValueError('Ambiguous Mochizuki release assets')
    tag = f"mochi-{mochi['tag_name']}_opti-{opti['tag_name'].removeprefix('nightly-')}"
    def entry(a, family):
        return {'url': valid_url(a.get('browser_download_url') or a['url'], family), 'asset_name': a['name']}
    return {'schema_version': 1, 'release_tag': tag, 'generated_at': datetime.now(timezone.utc).isoformat(),
        'optiscaler': dict(entry(asset, 'opti'), tag=opti['tag_name'], sha256=digest[7:].lower(), source_url=opti['html_url']),
        'mochizuki': dict(entry(windows[0], 'mochi'), tag=mochi['tag_name'], source_url=f"https://gitlab.com/mochizuki0323/DLSSNR-AMD/-/releases/{mochi['tag_name']}"),
        'cjk': entry(language[0], 'cjk') if language else None}


def release_exists(repo, tag):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Invalid target repository')
    try:
        release = api(f'{GH}/repos/{repo}/releases/tags/{urllib.parse.quote(tag)}')
        return not release['draft']
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


def emit(key, value):
    print(f'{key}={value}')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
            f.write(f'{key}={value}\n')


def package(lock, out):
    if not re.fullmatch(r'mochi-v[0-9]+\.[0-9]+\.[0-9]+_opti-[0-9]{8}', lock['release_tag']):
        raise ValueError('Unsafe release tag')
    out.mkdir(parents=True, exist_ok=True)
    filename = 'OptiScaler-Mochizuki-' + lock['release_tag'] + '-installer.zip'
    target = out / filename
    lock_text = json.dumps(lock, indent=2, ensure_ascii=False) + '\n'
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in ['install.cmd', 'Install.ps1']:
            z.write(ROOT / 'installer' / name, name)
        z.writestr('versions.lock.json', lock_text)
        if (ROOT / 'README.md').exists():
            z.write(ROOT / 'README.md', 'README.md')
        if (ROOT / 'LICENSE').exists():
            z.write(ROOT / 'LICENSE', 'LICENSE')
    if target.stat().st_size > 1024 * 1024:
        raise ValueError('Installer unexpectedly large')
    (out / 'versions.lock.json').write_text(lock_text, encoding='utf-8')
    (out / 'SHA256SUMS.txt').write_text(f'{sha(target)}  {filename}\n{sha(out / "versions.lock.json")}  versions.lock.json\n', encoding='utf-8')
    notes = f'''## Windows installer: {lock['release_tag']}

- OptiScaler: [{lock['optiscaler']['tag']}]({lock['optiscaler']['source_url']})
- Mochizuki: [{lock['mochizuki']['tag']}]({lock['mochizuki']['source_url']})

Download and extract the installer ZIP, then run install.cmd. It fetches the pinned official packages, checks their SHA-256 values, and combines them locally. Supply your own nvngx_dlssnr.dll when the upstream installer asks.

This release contains only installer scripts and a version/hash lock. No NVIDIA DLL, extracted model weights, or third-party runtime binaries are distributed here. The OptiScaler asset hash is checked against GitHub's release metadata; Mochizuki/CJK hashes are recorded from the HTTPS downloads. Archive layout and configuration contracts were checked. This does not establish in-game compatibility or performance. Test offline first; do not use with anti-cheat games.
'''
    (out / 'release-notes.md').write_text(notes, encoding='utf-8')
    emit('tag', lock['release_tag']); emit('built', 'true')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', ''))
    parser.add_argument('--out', type=Path, default=ROOT / 'dist')
    parser.add_argument('--offline-lock', type=Path, help='Test only: existing lock with sha256 values')
    parser.add_argument('--offline-assets', type=Path, help='Test only: asset files named as in the lock')
    args = parser.parse_args()
    if bool(args.offline_lock) != bool(args.offline_assets):
        parser.error('Both offline arguments are required together')
    lock = json.loads(args.offline_lock.read_text()) if args.offline_lock else find_releases()
    if not args.offline_lock and args.repository and release_exists(args.repository, lock['release_tag']):
        emit('tag', lock['release_tag']); emit('built', 'false'); return
    with tempfile.TemporaryDirectory(prefix='nr-upstream-') as work:
        paths = {}
        for key in ('optiscaler', 'mochizuki', 'cjk'):
            entry = lock[key]
            if entry is None:
                paths[key] = None; continue
            if PurePosixPath(entry['asset_name']).name != entry['asset_name'] or not re.fullmatch(r'[A-Za-z0-9._-]+', entry['asset_name']):
                raise ValueError('Unsafe asset name')
            path = Path(work) / entry['asset_name']
            if args.offline_assets:
                shutil.copyfile(args.offline_assets / entry['asset_name'], path)
                digest = sha(path)
            else:
                digest = download(valid_url(entry['url'], {'optiscaler': 'opti', 'mochizuki': 'mochi', 'cjk': 'cjk'}[key]), path)
            if entry.get('sha256') and entry['sha256'] != digest:
                raise ValueError('SHA256 mismatch for ' + key)
            entry['sha256'] = digest; paths[key] = path
        check_layout(paths['mochizuki'], paths['optiscaler'], paths['cjk'])
        package(lock, args.out)


if __name__ == '__main__':
    main()
