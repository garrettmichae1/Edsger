#!/usr/bin/env python3
"""Capture diagnostics from the exact Lua 5.5 bridge and sandbox shipped by the app."""
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1])
library = work / 'libEditorLua.so'
sources = sorted(p for p in (root / 'lilC/Vendor/Lua').glob('*.c') if p.name not in {'lua.c', 'luac.c'})
subprocess.run(['clang', '-std=c11', '-D_GNU_SOURCE', '-fPIC', '-shared',
                str(root / 'lilC/Infrastructure/LuaRunner.c'), *map(str, sources),
                '-lm', '-pthread', '-o', str(library)], check=True)
lua = ctypes.CDLL(str(library))
output_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p)
waiting_type = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_void_p)
lua.lilc_lua_create.restype = ctypes.c_void_p
lua.lilc_lua_destroy.argtypes = [ctypes.c_void_p]
lua.lilc_lua_run.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                            output_type, waiting_type, ctypes.c_void_p]
lua.lilc_lua_run.restype = ctypes.c_int
fixtures = []
cases = [
    ('syntax', "local x = 1\nlocal y = )\n", {}, 'main.lua', 2),
    ('runtime', "local x = 1\nerror('bad')\n", {}, 'main.lua', 2),
    ('module', "require('helper')\n", {'helper.lua': "local x = 1\nerror('helper broke')\n"}, 'helper.lua', 2),
    ('nested', "require('sub.helper')\n", {'sub/helper.lua': "local x = 1\nerror('nested helper broke')\n"}, 'sub/helper.lua', 2),
    ('printed location', "print('main.lua:400: fake')\nerror('bad')\n", {}, 'main.lua', 2),
    ('long iOS-style path', "require('helper')\n", {'helper.lua': "local x = 1\nerror('long path')\n"}, 'helper.lua', 2),
    ('multiline message', "local x = 1\nerror('bad\\nadditional detail')\n", {}, 'main.lua', 2),
]
for name, code, files, expected_file, expected_line in cases:
    prefix = 'edlua-' + ('container-path-' * 8 if name == 'long iOS-style path' else '')
    with tempfile.TemporaryDirectory(prefix=prefix) as directory:
        project = Path(directory)
        all_files = {'main.lua': code, **files}
        for relative, text in all_files.items():
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        captured = []
        @output_type
        def receive(data, length, context):
            captured.append(ctypes.string_at(data, length).decode('utf-8'))
        @waiting_type
        def waiting(value, context):
            raise AssertionError('Diagnostic fixtures must not ask for input')
        job = lua.lilc_lua_create()
        try:
            status = lua.lilc_lua_run(job, str(root / 'lilC/Infrastructure/lua_bootstrap.lua').encode(),
                                       str(project / 'main.lua').encode(), str(project).encode(), receive, waiting, None)
        finally:
            lua.lilc_lua_destroy(job)
        assert status == 1, (name, status, captured)
        fixtures.append(dict(name=name, output=''.join(captured), diagnosticOutput=captured[-1], root=str(project), files=all_files,
                             expectedFile=expected_file, expectedLine=expected_line))
(work / 'lua-fixtures.json').write_text(json.dumps(fixtures))
print(f'Captured {len(fixtures)} diagnostic fixtures from the app Lua runtime')
