"""Fresh interpreter setup for one local Python console run."""
import sys
import os
import io
import time
import traceback
import _lilc

class _Output(io.TextIOBase):
    def writable(self): return True
    def write(self, text): return _lilc.write(str(text))
    def flush(self): pass
    @property
    def encoding(self): return "utf-8"

class _Input(io.TextIOBase):
    def __init__(self):
        super().__init__()
        self.pending = ""
    def readable(self): return True
    def readline(self, size=-1):
        if size == 0: return ""
        if not self.pending: self.pending = _lilc.readline()
        end = self.pending.find("\n") + 1 or len(self.pending)
        if size >= 0: end = min(end, size)
        result, self.pending = self.pending[:end], self.pending[end:]
        return result
    def read(self, size=-1):
        chunks = []
        remaining = size
        while remaining != 0:
            chunk = self.readline(remaining)
            if not chunk: break
            chunks.append(chunk)
            if remaining > 0: remaining -= len(chunk)
        return "".join(chunks)
    @property
    def encoding(self): return "utf-8"

sys.stdout = sys.stderr = _Output()
sys.stdin = _Input()
sys.dont_write_bytecode = True
sys.argv = [_script_path]
sys.path.insert(0, _project_root)
time.sleep = _lilc.sleep
# Disable common process-control operations in the embedded console.
import posix
for _name in ("_exit", "fork", "forkpty", "execv", "execve", "posix_spawn", "posix_spawnp", "kill", "killpg", "abort", "open", "read", "write", "readv", "writev", "dup", "dup2", "close", "closerange", "pipe", "pipe2", "fdopen", "fchmod", "fchown", "ftruncate"):
    for _module in (os, posix):
        if hasattr(_module, _name): delattr(_module, _name)

# _thread may already be loaded by interpreter initialization, so import guards
# alone are insufficient. Remove its process-local thread entry points as well.
_threads = sys.modules.get('_thread')
if _threads is not None:
    for _name in ('start_new_thread', 'start_new', 'start_joinable_thread'):
        if hasattr(_threads, _name): delattr(_threads, _name)

# File, import, network and process restrictions are enforced by the native
# PySys_AddAuditHook installed before CPython initialization. Python globals
# are not an authority boundary, including during interpreter finalization.
os.chdir(_project_root)
_failed = False
try:
    _lilc.enable_trace()
    with open(_script_path, encoding="utf-8") as _file:
        _code = compile(_file.read(), _script_path, "exec")
    exec(_code, {"__name__": "__main__", "__file__": _script_path, "__builtins__": __builtins__})
except SystemExit as _exit:
    _failed = _exit.code not in (None, 0)
    if _failed: print("Exited with:", _exit.code)
except BaseException:
    _failed = True
    traceback.print_exc()
