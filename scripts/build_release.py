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

from release_identity import release_tag

ROOT = Path(__file__).resolve().parents[1]
GH = 'https://api.github.com'
UPSTREAM = 'OptiScaler/OptiScaler-nightly'
GL = 'https://gitlab.com/api/v4/projects/88319462'
MAX_DOWNLOAD = 1500 * 1024 * 1024
MAX_EXPANDED = 4 * 1024 ** 3
TAG = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$')


ASSET_FAMILIES = {
    'optiscaler': 'opti', 'mochizuki': 'mochi', 'cjk': 'cjk',
    'mfgunlocker': 'mfgunlocker', 'optipatcher': 'optipatcher',
    'openrr': 'openrr', 'anr': 'anr',
}


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
        'mfgunlocker': r'https://github\.com/dashdogy/MFG-Unlocker/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/MFGUnlocker-v[0-9]+\.[0-9]+\.[0-9]+\.zip',
        'optipatcher': r'https://github\.com/[Oo]pti[Ss]caler/OptiPatcher/releases/download/(?:rolling|v[0-9]+\.[0-9]+(?:\.[0-9]+)?)/OptiPatcher(?:_v[0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z]?)?\.asi',
        'openrr': r'https://github\.com/TheAutomatic/dlss-5-amd-project/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/OptiScaler-NR-[0-9]+\.[0-9]+\.[0-9]+\.zip',
        'anr': r'https://github\.com/apex-compute/ANR/releases/download/FG-V\.B[0-9]+/anr-fg-V\.B[0-9]+-addon\.zip',
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
    for key in ('FGInput', 'FGOutput', 'FGNvngxReplacement', 'DisableHudless'):
        if not config.has_option('FrameGen', key):
            raise ValueError('ANR/INI contract changed: FrameGen.' + key)
    if cjk:
        names, _ = read_zip(cjk, set())
        if 'lang/zh-cn.txt' not in names or not all(n.startswith('lang/') for n in names):
            raise ValueError('CJK archive layout changed')


def check_pe(data):
    # Read headers only; these downloaded DLLs are never loaded by the builder.
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('Plugin is not a PE image')
    offset = int.from_bytes(data[60:64], 'little')
    if offset + 26 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise ValueError('Invalid PE header')
    if int.from_bytes(data[offset + 4:offset + 6], 'little') != 0x8664:
        raise ValueError('Plugin is not x64')
    if not int.from_bytes(data[offset + 22:offset + 24], 'little') & 0x2000:
        raise ValueError('PE image is not a DLL')


def check_addons(paths, lock):
    names, _ = read_zip(paths['mfgunlocker'], set())
    with zipfile.ZipFile(paths['mfgunlocker']) as z:
        members = [i for i in z.infolist() if not i.is_dir() and i.filename == 'MFGUnlocker.dll']
        if len(members) != 1 or members[0].file_size > 128 * 1024 * 1024:
            raise ValueError('MFG Unlocker ZIP layout changed')
        check_pe(z.read(members[0]))
    if lock['mfgunlocker'].get('member') != 'MFGUnlocker.dll':
        raise ValueError('Unexpected MFG Unlocker member')
    if paths['optipatcher'].stat().st_size > 128 * 1024 * 1024:
        raise ValueError('OptiPatcher too large')
    check_pe(paths['optipatcher'].read_bytes())
    if lock['optipatcher'].get('member') is not None:
        raise ValueError('OptiPatcher must be a raw ASI')


def check_openrr(path):
    # Author's launcher uses backslashes in ZIP names. Inspect only the RR members;
    # the installer must never extract or execute the launcher or its other payloads.
    key = 'optiscaler/plugins/openrr-amd.asi'
    cfg = 'openrr-amd.ini'
    shaders = re.compile(r'openrr-amd/shaders(?:-gfx11)?/[A-Za-z0-9_.-]+\.spv')
    seen, selected = set(), {}
    import configparser
    with zipfile.ZipFile(path) as z:
        for member in z.infolist():
            name = member.filename.replace(chr(92), '/').lower()
            if name not in (key, cfg, 'licenses/openrr_mit.txt', 'licenses/openrr_third_party.md') and not shaders.fullmatch(name):
                continue
            safe_name(name, seen)
            mode = (member.external_attr >> 16) & 0o170000
            if member.is_dir() or mode not in (0, 0o100000) or member.file_size > 32 * 1024 * 1024:
                raise ValueError('Unexpected OpenRR member: ' + name)
            selected[name] = member
        required = {key, cfg, 'licenses/openrr_mit.txt', 'licenses/openrr_third_party.md',
                    'openrr-amd/shaders/ingest.spv', 'openrr-amd/shaders/post_f.spv'}
        if not required <= selected.keys() or sum(x.startswith('openrr-amd/shaders/') for x in selected) < 80:
            raise ValueError('OpenRR payload layout changed')
        check_pe(z.read(selected[key]))
        c = configparser.ConfigParser(interpolation=None)
        c.read_string(z.read(selected[cfg]).decode('utf-8-sig'))
        if c.getboolean('OpenRR', 'OptiFGHost', fallback=True):
            raise ValueError('OpenRR experimental bridge is not off by default')
        for name, member in selected.items():
            if shaders.fullmatch(name) and not z.read(member).startswith(b'\x03\x02\x23\x07'):
                raise ValueError('Invalid SPIR-V shader: ' + name)


def check_optional_addons(paths, lock):
    check_openrr(paths['openrr'])
    prefix = 'Apex Neural Rendering FG/dlssg/'
    fg = prefix + 'nvngx_dlssg.dll'
    names, _ = read_zip(paths['anr'], set())
    required = {fg.lower(), (prefix + 'nr_fg.ini').lower(), (prefix + 'kernels/pack.nrx').lower()}
    if not required <= names or lock['anr'].get('member') != 'Apex Neural Rendering FG':
        raise ValueError('ANR addon layout changed')
    with zipfile.ZipFile(paths['anr']) as z:
        for member in z.infolist():
            name = member.filename
            if name.startswith(prefix) and not member.is_dir() and not re.fullmatch(
                r'Apex Neural Rendering FG/dlssg/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(?:dll|ini|json|nrx)', name
            ):
                raise ValueError('Unexpected ANR provider member: ' + name)
        if z.getinfo(fg).file_size > 32 * 1024 * 1024:
            raise ValueError('ANR provider DLL is too large')
        check_pe(z.read(fg))


def github_plugin(repo, pattern, family, member, rolling=False, prerelease=False):
    releases = api(f'{GH}/repos/{repo}/releases?per_page=20')
    if rolling and not any(r['tag_name'] == 'rolling' for r in releases):
        try:
            releases.append(api(f'{GH}/repos/{repo}/releases/tags/rolling'))
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    candidates = [(r, a) for r in releases if not r['draft'] and (prerelease or not r['prerelease'])
                  for a in r['assets'] if re.fullmatch(pattern, a['name'])]
    if not candidates:
        raise ValueError('No plugin asset found for ' + repo)
    # Rolling tags are updated in place; publication date alone is incorrect.
    release, asset = max(candidates, key=lambda pair: (pair[1]['updated_at'], pair[1]['id']))
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', digest):
        raise ValueError('Published SHA256 missing for ' + repo)
    if not TAG.fullmatch(release['tag_name']):
        raise ValueError('Unsafe plugin tag')
    return {'tag': release['tag_name'], 'url': valid_url(asset['browser_download_url'], family),
            'sha256': digest[7:].lower(), 'asset_name': asset['name'],
            'source_url': release['html_url'], 'member': member,
            'asset_id': asset['id'], 'asset_updated_at': asset['updated_at']}


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
    mfg = github_plugin('dashdogy/MFG-Unlocker', r'MFGUnlocker-v[0-9]+\.[0-9]+\.[0-9]+\.zip', 'mfgunlocker', 'MFGUnlocker.dll')
    patch = github_plugin('optiscaler/OptiPatcher', r'OptiPatcher(?:_v[0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z]?)?\.asi', 'optipatcher', None, rolling=True)
    rr = github_plugin('TheAutomatic/dlss-5-amd-project', r'OptiScaler-NR-[0-9]+\.[0-9]+\.[0-9]+\.zip', 'openrr', None)
    anr = github_plugin('apex-compute/ANR', r'anr-fg-V\.B[0-9]+-addon\.zip', 'anr', 'Apex Neural Rendering FG', prerelease=True)
    if rr['asset_name'] != 'OptiScaler-NR-' + rr['tag'].removeprefix('v') + '.zip':
        raise ValueError('OpenRR launcher tag and filename disagree')
    if anr['asset_name'] != 'anr-fg-' + anr['tag'].removeprefix('FG-') + '-addon.zip':
        raise ValueError('ANR tag and filename disagree')
    def entry(a, family):
        return {'url': valid_url(a.get('browser_download_url') or a['url'], family), 'asset_name': a['name']}
    return {'schema_version': 3, 'installer_edition': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
        'optiscaler': dict(entry(asset, 'opti'), tag=opti['tag_name'], sha256=digest[7:].lower(), source_url=opti['html_url']),
        'mochizuki': dict(entry(windows[0], 'mochi'), tag=mochi['tag_name'], source_url=f"https://gitlab.com/mochizuki0323/DLSSNR-AMD/-/releases/{mochi['tag_name']}"),
        'cjk': entry(language[0], 'cjk') if language else None,
        'mfgunlocker': mfg, 'optipatcher': patch, 'openrr': rr, 'anr': anr}


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
    if not re.fullmatch(r'bundle-[0-9]{8}-[a-f0-9]{20}', lock['release_tag']):
        raise ValueError('Unsafe release tag')
    out.mkdir(parents=True, exist_ok=True)
    filename = 'OptiScaler-Manager-' + lock['release_tag'] + '.zip'
    target = out / filename
    lock_text = json.dumps(lock, indent=2, ensure_ascii=False) + '\n'
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(ROOT / 'manager' / 'OptiScaler Manager.cmd', 'OptiScaler Manager.cmd')
        for name in ('Manager.ps1', 'ManagerStore.ps1', 'ManagerEngine.ps1'):
            z.write(ROOT / 'manager' / name, 'app/' + name)
        for script in sorted((ROOT / 'installer').glob('*.ps1')):
            z.write(script, 'app/installer/' + script.name)
        z.writestr('app/versions.lock.json', lock_text)
        if (ROOT / 'README.md').exists():
            z.write(ROOT / 'README.md', 'app/README.md')
        if (ROOT / 'LICENSE').exists():
            z.write(ROOT / 'LICENSE', 'app/LICENSE')
    if target.stat().st_size > 1024 * 1024:
        raise ValueError('Installer unexpectedly large')
    (out / 'versions.lock.json').write_text(lock_text, encoding='utf-8')
    (out / 'SHA256SUMS.txt').write_text(f'{sha(target)}  {filename}\n{sha(out / "versions.lock.json")}  versions.lock.json\n', encoding='utf-8')
    notes = f'''## OptiScaler Windows Manager: {lock['release_tag']}

- OptiScaler: [{lock['optiscaler']['tag']}]({lock['optiscaler']['source_url']})
- Mochizuki: [{lock['mochizuki']['tag']}]({lock['mochizuki']['source_url']})
- MFG Unlocker: [{lock['mfgunlocker']['tag']}]({lock['mfgunlocker']['source_url']})
- OptiPatcher: [{lock['optipatcher']['tag']}]({lock['optipatcher']['source_url']}) (asset SHA-256 {lock['optipatcher']['sha256'][:12]})
- OpenRR-ASI: [{lock['openrr']['tag']} launcher asset]({lock['openrr']['source_url']}) (RX 9000 and your own nvngx_dlssd.dll 310.9.1)
- ANR FG: [{lock['anr']['tag']} addon]({lock['anr']['source_url']}) (requires a supported FG input; selectable in OptiScaler alongside the installed XeMFG backend)

ASI loading is enabled by default. Official OptiScaler nightly is retained; MFG Unlocker features requiring its author's OptiScaler fork are not enabled by this bundle. Only one NR provider should be active at once. ANR and MFG Unlocker coexist on disk. OptiScaler selects a single active frame-generation backend. OpenRR is prepared by default, activates only on supported hardware with the matching local DLL, and does not enable the experimental OptiFG bridge.

Download and extract the Manager ZIP, then open **OptiScaler Manager.cmd**. Add each game once, install or adopt it, and manage updates, OpenRR and rollback in one window. Choose ANR or XeMFG in the OptiScaler in-game menu, then save and restart as directed. Your NVIDIA DLLs are imported once per type and version into a fixed local library. They and the model weights stay on your PC. Existing installations can be adopted without reinstalling. Keep the app directory beside the launcher. The manager checks component updates on demand; it does not replace its own code silently. Older script-only releases remain available under their original tags.

This release contains only installer scripts and a version/hash lock. No NVIDIA DLL, extracted model weights, or third-party runtime binaries are distributed here. The GitHub asset hashes are checked against GitHub's release metadata; Mochizuki/CJK hashes are recorded from the HTTPS downloads. Archive layout and configuration contracts were checked. This does not establish in-game compatibility or performance. Test offline first; do not use with anti-cheat games.
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
    lock = json.loads(args.offline_lock.read_text(encoding='utf-8-sig')) if args.offline_lock else find_releases()
    with tempfile.TemporaryDirectory(prefix='nr-upstream-') as work:
        paths = {}
        def stage(key):
            entry = lock[key]
            if entry is None:
                paths[key] = None
                return
            if not re.fullmatch(r'[A-Za-z0-9._-]+', entry['asset_name']) or entry['asset_name'] in ('.', '..'):
                raise ValueError('Unsafe asset name')
            path = Path(work) / (key + '-' + entry['asset_name'])
            if args.offline_assets:
                shutil.copyfile(args.offline_assets / entry['asset_name'], path)
                digest = sha(path)
            else:
                digest = download(valid_url(entry['url'], ASSET_FAMILIES[key]), path)
            if entry.get('sha256') and entry['sha256'] != digest:
                raise ValueError('SHA256 mismatch for ' + key)
            entry['sha256'] = digest
            paths[key] = path

        # GitLab assets lack a trusted digest in metadata. Hash them before deduplication.
        # GitHub supplies digests, so unchanged runs need not fetch the large optional launcher.
        for key in ASSET_FAMILIES:
            if lock[key] is None or not lock[key].get('sha256'):
                if key not in ('mochizuki', 'cjk') and lock[key] is not None:
                    raise ValueError('Missing published SHA256 for ' + key)
                stage(key)
        lock['release_tag'] = release_tag(lock, ROOT)
        if not args.offline_lock and args.repository and release_exists(args.repository, lock['release_tag']):
            emit('tag', lock['release_tag']); emit('built', 'false'); return
        for key in ASSET_FAMILIES:
            if key not in paths:
                stage(key)
        check_layout(paths['mochizuki'], paths['optiscaler'], paths['cjk'])
        check_addons(paths, lock)
        check_optional_addons(paths, lock)
        package(lock, args.out)


if __name__ == '__main__':
    main()
