#!/usr/bin/env python3
"""Package pinned math wheels with the minimal iOS compatibility adjustment.

SymPy 1.14 imports ctypes solely to calculate native C long's size in gmpy.py,
even when its pure-Python ground types are used. struct supplies the same native
size without shipping _ctypes/FFI. Keep this exact-source patch tied to the
checksum-verified wheel, and fail the build if upstream changes it.
"""
from pathlib import Path
import runpy
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def bundle_math_packages(destination):
    destination = Path(destination)
    assets = runpy.run_path(str(ROOT / 'scripts/fetch-math-assets.py'))
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for name, _, digest in assets['ASSETS']:
        wheel = assets['verified_asset'](name, digest)
        with zipfile.ZipFile(wheel) as archive:
            for entry in archive.infolist():
                relative = Path(entry.filename)
                if relative.is_absolute() or '..' in relative.parts:
                    raise ValueError('Invalid math wheel path')
                if 'tests' in relative.parts or '__pycache__' in relative.parts:
                    continue
                archive.extract(entry, destination)

    gmpy = destination / 'sympy/external/gmpy.py'
    source = gmpy.read_text()
    replacements = {
        'from ctypes import c_long, sizeof\n': 'from struct import calcsize\n',
        'LONG_MAX = (1 << (8*sizeof(c_long) - 1)) - 1': "LONG_MAX = (1 << (8*calcsize('l') - 1)) - 1",
    }
    for original, replacement in replacements.items():
        if source.count(original) != 1:
            raise ValueError('Pinned SymPy C-long compatibility patch no longer matches')
        source = source.replace(original, replacement)
    if 'c_long' in source or 'sizeof' in source or 'ctypes' in source:
        raise ValueError('Unexpected SymPy C-long dependency remains')
    gmpy.write_text(source)


if __name__ == '__main__':
    import sys
    bundle_math_packages(sys.argv[1])
