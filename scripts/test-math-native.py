#!/usr/bin/env python3
"""Build/run the production bridge with host Python headers and the shipped math packages.
This checks C lifecycle behavior; it does not replace an iOS device build/test.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import sysconfig
import tempfile
import runpy

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='edsger-math-native-') as directory:
    work = Path(directory)
    packages = work / 'math-packages'
    runpy.run_path(str(root / 'scripts/bundle-math-packages.py'))['bundle_math_packages'](packages)
    # Model the extension absent from the iPhone bundle, even on a desktop
    # where _ctypes is installed. This must stay absent throughout cold/warm
    # math interpreter creation; do not accidentally test desktop SymPy.
    bootstrap = work / 'math_bootstrap.py'
    bootstrap.write_text("import sys\nsys.modules['_ctypes'] = None\n" +
                         (root / 'lilC/Infrastructure/math_bootstrap.py').read_text())
    (work / 'Python').mkdir()
    (work / 'Python/Python.h').write_text('#include <Python.h>\n')
    script = work / 'main.py'
    script.write_text("import sys\nassert 'sympy' not in sys.modules\ninput()\n")
    slow_bootstrap = work / 'slow_bootstrap.py'
    slow_bootstrap.write_text("import time\ntime.sleep(0.2)\ndef _calculate_json(request):\n    return '{\"ok\": true, \"exact\": \"1/2\"}'\n")
    binary = work / 'native-smoke'
    library = sysconfig.get_config_var('LDLIBRARY')
    libdir = Path(sysconfig.get_config_var('LIBDIR'))
    if not (libdir / library).exists(): libdir = Path(sys.base_prefix) / 'lib'
    link_library = libdir / library
    if not link_library.exists():
        link_library = next((p for p in libdir.glob(library + ".*") if p.is_file()), link_library)
    if not link_library.exists(): raise SystemExit("Host Python development library is missing.")
    command = [os.environ.get('CC', 'cc'), '-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
               '-I' + str(work), '-I' + sysconfig.get_path('include'), '-I' + str(root / 'lilC/Infrastructure'),
               str(root / 'lilC/Infrastructure/PythonRunner.c'), str(root / 'scripts/math-native-smoke.c'),
               '-L' + str(libdir), '-Wl,-rpath,' + str(libdir), str(link_library),
               *shlex.split(sysconfig.get_config_var('LIBS') or ''), *shlex.split(sysconfig.get_config_var('SYSLIBS') or ''),
               '-lpthread', '-o', str(binary)]
    subprocess.run(command, check=True)
    args = [str(binary), sys.base_prefix, str(packages), str(bootstrap),
            str(root / 'lilC/Infrastructure/python_bootstrap.py'), str(script), str(work), str(slow_bootstrap)]
    for order in ([], ['ide-first']):
        subprocess.run([*args, *order], check=True, timeout=60)
    # Exercise every portable calculation/domain regression with the exact
    # packaged library and unavailable FFI, instead of an installed SymPy.
    engine = str(root / 'scripts/test-math-engine.py')
    subprocess.run([sys.executable, '-c',
                    "import sys, runpy; sys.path.insert(0, sys.argv[1]); "
                    "sys.modules['_ctypes'] = None; "
                    "script = sys.argv[2]; sys.argv = [script]; runpy.run_path(script, run_name='__main__')",
                    str(packages), engine], check=True, timeout=60)
