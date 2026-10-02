#!/usr/bin/env python3
"""Build/run the production bridge with host Python headers. Requires a compiler and pinned SymPy.
This checks C lifecycle behavior; it does not replace an iOS device build/test.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import sysconfig
import tempfile
import sympy

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='edsger-math-native-') as directory:
    work = Path(directory)
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
    subprocess.run([str(binary), sys.base_prefix, str(Path(sympy.__file__).parent.parent),
                    str(root / 'lilC/Infrastructure/math_bootstrap.py'), str(root / 'lilC/Infrastructure/python_bootstrap.py'),
                    str(script), str(work), str(slow_bootstrap)], check=True, timeout=45)
