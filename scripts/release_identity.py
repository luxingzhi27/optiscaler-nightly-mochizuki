"""Content-based installer identity; timestamps do not create new releases."""
import hashlib
import json
from pathlib import Path
import re

# These fields describe when discovery happened, not what will be installed.
_VOLATILE = frozenset({'generated_at', 'release_tag', 'asset_id', 'asset_updated_at'})


def _stable(value):
    if isinstance(value, dict):
        return {key: _stable(item) for key, item in value.items() if key not in _VOLATILE}
    if isinstance(value, list):
        return [_stable(item) for item in value]
    return value


def _check_asset_hashes(value):
    """A downloadable component must have a content identity before deduplication."""
    if isinstance(value, dict):
        if 'url' in value and 'asset_name' in value:
            digest = value.get('sha256', '')
            if not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest):
                raise ValueError('Asset SHA-256 is required before release identity: ' + str(value['asset_name']))
        for item in value.values():
            _check_asset_hashes(item)
    elif isinstance(value, list):
        for item in value:
            _check_asset_hashes(item)


def build_identity(lock, root):
    """Hash complete component contracts plus shipped files and builder logic.

    Includes every nonvolatile lock field, including URLs, hashes, archive members,
    optional-component settings and layout contracts. Unknown fields are included
    by default so extending the installer cannot silently reuse an old release.
    Caller must resolve every downloadable asset hash before calling this.
    """
    _check_asset_hashes(lock)
    root = Path(root)
    files = set()
    for folder in ('installer', 'scripts'):
        files.update(path for path in (root / folder).rglob('*')
                     if path.is_file() and '__pycache__' not in path.parts
                     and path.suffix != '.pyc')
    files.update(root / name for name in ('README.md', 'LICENSE') if (root / name).is_file())
    content = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in sorted(files)}
    payload = {'identity_version': 1, 'lock': _stable(lock), 'files': content}
    canonical = json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return hashlib.sha256(canonical.encode('utf-8')).hexdigest()


def release_tag(lock, root):
    nightly = lock.get('optiscaler', {}).get('tag', '')
    if not re.fullmatch(r'nightly-[0-9]{8}', nightly):
        raise ValueError('Expected an OptiScaler nightly date for release identity')
    return 'bundle-' + nightly.removeprefix('nightly-') + '-' + build_identity(lock, root)[:20]
