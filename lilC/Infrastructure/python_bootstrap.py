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
for _name in ("_exit", "fork", "forkpty", "execv", "execve", "posix_spawn", "posix_spawnp", "kill", "killpg", "abort"):
    for _module in (os, posix):
        if hasattr(_module, _name): delattr(_module, _name)

_read_roots = tuple(os.path.realpath(p) for p in (sys.base_prefix, _project_root))
_project_root = os.path.realpath(_project_root)
def _inside(path, root):
    return path == root or path.startswith(root + os.sep)
_finishing = False
def _audit(event, args):
    if _finishing: return
    if event == "import" and args[0].split('.')[0] in {"ctypes", "_ctypes", "subprocess", "multiprocessing", "threading", "_thread", "socket", "_socket", "signal", "resource"}:
        raise ImportError("This module is unavailable in lilC's Python console.")
    if event in {"sys.settrace", "sys.setprofile", "os.system", "os.chdir", "os.fchdir"} or event.startswith(("subprocess.", "ctypes.", "socket.")):
        raise PermissionError("This operation is unavailable in lilC's Python console.")
    if event == "open":
        path, mode, flags = args
        if not isinstance(path, (str, bytes, os.PathLike)):
            raise PermissionError("Raw file descriptors are unavailable.")
        path = os.path.realpath(os.fsdecode(path))
        writing = bool(flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND))
        if writing:
            space = os.statvfs(_project_root)
            if space.f_bavail * space.f_frsize < 1024 * 1024:
                raise OSError("Not enough free space to write project files.")
        roots = (_project_root,) if writing else _read_roots
        if not any(_inside(path, root) for root in roots):
            raise PermissionError("Files must stay inside this Python project.")
    if event in {"os.remove", "os.rmdir", "os.mkdir", "os.rename", "os.link", "os.symlink", "os.chmod", "os.chown", "os.truncate", "os.utime"}:
        paths = args[:2] if event in {"os.rename", "os.link", "os.symlink"} else args[:1]
        if event in {"os.link", "os.symlink"} or any(not isinstance(p, (str, bytes, os.PathLike)) or not _inside(os.path.realpath(os.fsdecode(p)), _project_root) for p in paths):
            raise PermissionError("Files must stay inside this Python project.")
    if event == "sqlite3.connect" and args[0] != ":memory:":
        database = os.fsdecode(args[0])
        if database.startswith("file:") or not _inside(os.path.realpath(database), _project_root):
            raise PermissionError("Databases must stay inside this Python project.")

os.chdir(_project_root)
_failed = False
try:
    _lilc.enable_trace()
    sys.addaudithook(_audit)
    with open(_script_path, encoding="utf-8") as _file:
        _code = compile(_file.read(), _script_path, "exec")
    exec(_code, {"__name__": "__main__", "__file__": _script_path, "__builtins__": __builtins__})
except SystemExit as _exit:
    _failed = _exit.code not in (None, 0)
    if _failed: print("Exited with:", _exit.code)
except BaseException:
    _failed = True
    traceback.print_exc()
