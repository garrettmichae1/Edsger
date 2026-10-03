#!/usr/bin/env python3
"""Compile and exercise the actual embedded runner using a host CPython.

Host checks cover native policy behavior; iOS compilation/device tests remain
separate because the app uses its pinned Apple CPython framework.
"""
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = r'''
#include "PythonRunner.h"
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
static void *stop_later(void *context) { usleep(50000); lilc_python_stop(context); return NULL; }
static void output(const char *text, int count, void *context) { (void)context; fwrite(text, 1, count, stdout); }
static void waiting(int value, void *context) { (void)value; (void)context; }
int main(int argc, char **argv) {
    if (argc != 5 && argc != 6) return 9;
    lilc_python_job *job = lilc_python_create();
    pthread_t stopper;
    if (argc == 6) pthread_create(&stopper, NULL, stop_later, job);
    int result = lilc_python_run(job, argv[1], argv[2], argv[3], argv[4], output, waiting, NULL);
    if (argc == 6) pthread_join(stopper, NULL);
    lilc_python_destroy(job);
    return result;
}
'''
with tempfile.TemporaryDirectory(prefix='edsger-python-safety-') as temporary:
    directory = pathlib.Path(temporary)
    harness = directory / 'runner.c'; harness.write_text(HARNESS)
    executable = directory / 'runner'
    config = os.environ.get('PYTHON_CONFIG', 'python3-config')
    flags = shlex.split(subprocess.check_output([config, '--includes', '--embed', '--ldflags'], text=True))
    library_paths = [f[2:] for f in flags if f.startswith('-L')]
    for index, flag in enumerate(flags):
        if flag.startswith('-lpython'):
            for library_path in library_paths:
                library = pathlib.Path(library_path) / ('lib' + flag[2:] + '.so')
                versioned = library.with_name(library.name + '.1.0')
                if not library.exists() and versioned.exists():
                    flags[index] = str(versioned)
    compiler = os.environ.get('CC', 'cc')
    subprocess.run([compiler, '-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-I' + str(ROOT / 'lilC/Infrastructure'), str(harness), str(ROOT / 'lilC/Infrastructure/PythonRunner.c'),
                    *flags, *['-Wl,-rpath,' + p for p in library_paths], '-o', str(executable)], check=True)
    project = directory / 'project'; project.mkdir()
    outside = directory / 'outside.txt'; outside.write_text('OUTSIDE_SENTINEL')
    link = project / 'outside-link'; link.symlink_to(outside)
    (project / 'dangling-link').symlink_to(directory / 'new.txt')
    script = project / 'main.py'
    cases = {
        'normal program and project file': ("import math, json, pathlib\np=pathlib.Path('result.txt')\np.write_text(json.dumps({'answer':math.sqrt(81)}))\nprint(p.read_text())", True, '9.0'),
        'default directory listing': ("import os\nprint('main.py' in os.listdir())", True, 'True'),
        'raw descriptor APIs removed': ("import os, sys\nprint(not hasattr(os, 'read') and not hasattr(sys.modules['posix'], 'open'))", True, 'True'),
        'preloaded thread APIs removed': ("import sys\nprint(not hasattr(sys.modules.get('_thread'), 'start_new_thread'))", True, 'True'),
        'outside read': (f"print(open({str(outside)!r}).read())", False, 'PermissionError'),
        'original bootstrap-global bypass': (f"import sys\nsys._getframe(1).f_globals['_finishing']=True\nsys._getframe(1).f_globals['_project_root']={str(directory)!r}\nprint(open({str(outside)!r}).read())", False, 'PermissionError'),
        'symlink read': ("print(open('outside-link').read())", False, 'PermissionError'),
        'symlink write': ("open('outside-link','w').write('changed')", False, 'PermissionError'),
        'dangling symlink write': ("open('dangling-link','w').write('changed')", False, 'PermissionError'),
        'parent traversal': ("open('../new.txt','w').write('changed')", False, 'PermissionError'),
        'outside directory listing': (f"import os\nprint(os.listdir({str(directory)!r}))", False, 'PermissionError'),
        'directory-fd mutation': ("import os\nos.remove('main.py', dir_fd=1)", False, 'PermissionError'),
        'outside deletion': (f"import os\nos.remove({str(outside)!r})", False, 'PermissionError'),
        'socket import': ("import socket\nprint(socket.socket())", False, 'PermissionError'),
        'ctypes import': ("import ctypes", False, 'PermissionError'),
        'subprocess import': ("import subprocess", False, 'PermissionError'),
        'trace removal': ("import sys\nsys.settrace(None)", False, 'PermissionError'),
        'adding a Python audit hook': ("import sys\nsys.addaudithook(lambda *args: print('HOOK_INSTALLED'))\nprint('hook attempt ignored')", True, 'hook attempt ignored'),
        'raw descriptor open': ("open(1,'w',closefd=False)", False, 'PermissionError'),
        'sqlite outside project': (f"import sqlite3\nsqlite3.connect({str(directory / 'private.sqlite')!r})", False, 'PermissionError'),
        'native Stop interrupts a loop': ("while True: pass", False, 'KeyboardInterrupt'),
        'finalizer bypass': (f"import sys\nclass Evil:\n def __del__(self):\n  open({str(outside)!r},'w').write('changed')\nx=Evil()\nprint('finalizer registered')", True, 'finalizer registered'),
    }
    for name, (source, success, expected) in cases.items():
        script.write_text(source + '\n')
        result = subprocess.run([str(executable), sys.prefix, str(ROOT / 'lilC/Infrastructure/python_bootstrap.py'), str(script), str(project), *(['stop'] if name == 'native Stop interrupts a loop' else [])], capture_output=True, text=True, timeout=15)
        transcript = result.stdout + result.stderr
        if name == 'native Stop interrupts a loop': assert result.returncode == 2, transcript
        assert (result.returncode == 0) == success, (name, result.returncode, transcript)
        assert expected in transcript, (name, transcript)
        assert 'HOOK_INSTALLED' not in transcript, name
        assert outside.read_text() == 'OUTSIDE_SENTINEL', name
        assert not (directory / 'new.txt').exists(), name
        assert not (directory / 'private.sqlite').exists(), name
        print('PASS: ' + name)
    print(f'{len(cases)} native Python safety checks passed.')
