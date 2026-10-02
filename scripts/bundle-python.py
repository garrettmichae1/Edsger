#!/usr/bin/env python3
"""Xcode phase: package standard library and signed .fwork extension frameworks."""
import os, pathlib, plistlib, shutil, subprocess
root = pathlib.Path(os.environ['PROJECT_DIR'])
source = root / 'vendor/python/3.14-b11/Python.xcframework'
if not source.exists():
    raise SystemExit('Run scripts/fetch-python-assets.sh before building lilC.')
app = pathlib.Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
platform = os.environ['PLATFORM_NAME']
if platform not in ('iphoneos', 'iphonesimulator'):
    raise SystemExit('Unsupported Python platform: ' + platform)
arches = os.environ['ARCHS'].split()
slice_dir = source / ('ios-arm64' if platform == 'iphoneos' else 'ios-arm64_x86_64-simulator')
lib = app / 'python/lib/python3.14'
if lib.parent.parent.exists(): shutil.rmtree(lib.parent.parent)
shutil.copytree(source / 'lib/python3.14', lib, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
# Merge per-architecture configuration; extension binaries are combined below.
for arch in arches:
    archlib = slice_dir / ('lib-' + arch) / 'python3.14'
    if not archlib.exists(): raise SystemExit('Unsupported Python architecture: ' + arch)
    shutil.copytree(archlib, lib, dirs_exist_ok=True)
frameworks = app / 'Frameworks'
frameworks.mkdir(exist_ok=True)
for stale in frameworks.glob('PythonModule-*.framework'): shutil.rmtree(stale)
# Upstream test-only extensions are not part of the supported student library.
for pattern in ('_test*.so', '_xxtest*.so', 'xx*.so'):
    for file in (lib / 'lib-dynload').glob(pattern): file.unlink()
shutil.rmtree(lib / 'test', ignore_errors=True)
for ext in sorted((lib / 'lib-dynload').glob('*.so')):
    name = ext.name.split('.')[0]
    binary_name = 'PythonModule-' + name.replace('_', '-')
    framework = frameworks / (binary_name + '.framework')
    framework.mkdir()
    binary = framework / binary_name
    inputs = [slice_dir / ('lib-' + arch) / 'python3.14/lib-dynload' / ext.name for arch in arches]
    if len(inputs) == 1: shutil.copyfile(inputs[0], binary)
    else: subprocess.run(['xcrun', 'lipo', '-create', *map(str, inputs), '-output', str(binary)], check=True)
    binary.chmod(0o755)
    info = dict(CFBundleExecutable=binary_name, CFBundleIdentifier=os.environ['PRODUCT_BUNDLE_IDENTIFIER'] + '.' + binary_name,
                CFBundleName=binary_name, CFBundlePackageType='FMWK', CFBundleShortVersionString='3.14.7', CFBundleVersion='11',
                MinimumOSVersion='13.0', CFBundleSupportedPlatforms=['iPhoneOS' if platform == 'iphoneos' else 'iPhoneSimulator'])
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    marker = ext.with_suffix('.fwork')
    marker.write_text(str(binary.relative_to(app)) + '\n')
    (framework / (binary_name + '.origin')).write_text(str(marker.relative_to(app)) + '\n')
    ext.unlink()
    # OpenSSL is statically included in these two modules. No telemetry is enabled.
    if name in ('_ssl', '_hashlib'):
        shutil.copyfile(root / 'vendor/python/OpenSSL-PrivacyInfo.xcprivacy', framework / 'PrivacyInfo.xcprivacy')
    if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO':
        identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', str(framework)], check=True)
core = frameworks / 'Python.framework'
shutil.copyfile(root / 'vendor/python/Python-PrivacyInfo.xcprivacy', core / 'PrivacyInfo.xcprivacy')
if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO':
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-', '--timestamp=none', str(core)], check=True)
shutil.copytree(root / 'vendor/python/licenses', app / 'Python-Licenses', dirs_exist_ok=True)
shutil.copyfile(root / 'lilC/Infrastructure/python_bootstrap.py', app / 'python_bootstrap.py')
print('Bundled CPython 3.14.7 standard library and extension frameworks.')

for name in ('javascript_bootstrap.js', 'lua_bootstrap.lua'):
    shutil.copyfile(root / 'lilC/Infrastructure' / name, app / name)
shutil.copyfile(root / 'vendor/javascript/acorn.js', app / 'acorn.js')
shutil.copyfile(root / 'vendor/javascript/Acorn-LICENSE.txt', app / 'Python-Licenses/Acorn-LICENSE.txt')
shutil.copyfile(root / 'lilC/Vendor/Lua/LICENSE.txt', app / 'Python-Licenses/Lua-LICENSE.txt')

# Math lives outside the IDE import path, in a dedicated calculator interpreter.
import runpy, zipfile
math_assets = runpy.run_path(str(root / 'scripts/fetch-math-assets.py'))
math_packages = app / 'math-packages'
if math_packages.exists(): shutil.rmtree(math_packages)
math_packages.mkdir()
for name, _, digest in math_assets['ASSETS']:
    wheel = math_assets['verified_asset'](name, digest)
    with zipfile.ZipFile(wheel) as archive:
        for entry in archive.infolist():
            relative = pathlib.PurePosixPath(entry.filename)
            if relative.is_absolute() or '..' in relative.parts:
                raise SystemExit('Invalid math wheel path')
            if 'tests' in relative.parts or '__pycache__' in relative.parts:
                continue
            archive.extract(entry, math_packages)
shutil.copyfile(root / 'lilC/Infrastructure/math_bootstrap.py', app / 'math_bootstrap.py')
print('Bundled SymPy 1.14.0 and mpmath 1.3.0 for offline calculations.')
