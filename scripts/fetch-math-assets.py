#!/usr/bin/env python3
"""Download pinned pure-Python math wheels; no pip, builds, or runtime downloads."""
import hashlib
from pathlib import Path
from urllib.request import urlopen

ASSETS = [
    ('sympy-1.14.0-py3-none-any.whl', 'https://files.pythonhosted.org/packages/a2/09/77d55d46fd61b4a135c444fc97158ef34a095e5681d0a6c10b75bf356191/sympy-1.14.0-py3-none-any.whl', 'e091cc3e99d2141a0ba2847328f5479b05d94a6635cb96148ccb3f34671bd8f5'),
    ('mpmath-1.3.0-py3-none-any.whl', 'https://files.pythonhosted.org/packages/43/e3/7d92a15f894aa0c9c4b49b8ee9ac9850d6e63b03c9c32c0367a13ae62209/mpmath-1.3.0-py3-none-any.whl', 'a0b2b9fe80bbcd81a6647ff13108738cfb482d481d826cc0e02f5b35e5c88d2c'),
]
ROOT = Path(__file__).resolve().parents[1] / 'vendor/math'

def verified_asset(name, digest):
    path = ROOT / name
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('Missing or invalid math asset; run python3 scripts/fetch-math-assets.py: ' + name)
    return path

if __name__ == '__main__':
    ROOT.mkdir(parents=True, exist_ok=True)
    for name, url, digest in ASSETS:
        try:
            verified_asset(name, digest)
        except ValueError:
            data = urlopen(url, timeout=60).read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError('Math asset checksum mismatch: ' + name)
            (ROOT / name).write_bytes(data)
        print('Verified ' + name)
