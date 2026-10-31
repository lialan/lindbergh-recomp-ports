"""Package the PC VR executables and their transitive DLLs, without game data."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("build", type=Path)
parser.add_argument("deps", type=Path)
parser.add_argument("elf_hash", type=Path)
args = parser.parse_args()
out = args.build / "hotd4-pcvr"
out.mkdir(exist_ok=True)
objdump = shutil.which("x86_64-w64-mingw32-objdump") or shutil.which("objdump")
if not objdump:
    parser.error("MinGW objdump is required for DLL dependency verification")
available = {p.name.lower(): p for p in (args.deps / "bin").glob("*.dll")}
# System libraries shipped by Windows, rather than redistributable toolchain DLLs.
system = set("advapi32 avrt bcrypt cfgmgr32 comdlg32 crypt32 dinput8 dsound dwmapi dxgi gdi32 hid imm32 iphlpapi kernel32 ksuser msvcrt ntdll ole32 oleaut32 opengl32 powrprof propsys psapi rpcrt4 secur32 setupapi shell32 shlwapi user32 ucrtbase userenv version winmm winspool ws2_32 wtsapi32".split())
pending = [args.build / "hotd4.exe", args.build / "lindberghrecomp/lindbergh_rt_selftest.exe"]
files = {}
while pending:
    src = pending.pop()
    if src.name.lower() in files:
        continue
    data = src.read_bytes()
    files[src.name.lower()] = {"name": src.name, "sha256": hashlib.sha256(data).hexdigest()}
    shutil.copy2(src, out / src.name)
    imports = subprocess.check_output([objdump, "-p", str(src)], text=True)
    for name in re.findall(r"DLL Name:\s*(\S+)", imports):
        key = name.lower()
        if key in available:
            pending.append(available[key])
        elif key.removesuffix(".dll") not in system and not key.startswith(("api-ms-win-", "ext-ms-win-")):
            raise SystemExit(f"Unresolved DLL: {name} imported by {src.name}")
root = Path(__file__).resolve().parent
shutil.copy2(root / "run-hotd4-windows.ps1", out)
shutil.copy2(root.parent / "docs/hotd4/WINDOWS-PCVR.md", out / "README.md")
shutil.copy2(args.elf_hash, out / "hod4M.elf.sha256")
licenses = out / "licenses"
licenses.mkdir(exist_ok=True)
for name in ("SDL2", "glew", "openal", "openxr-sdk", "libmysofa", "zlib", "libiconv", "libgcc", "libstdc++", "libwinpthread"):
    src = args.deps / "share/licenses" / name
    if src.is_dir():
        shutil.copytree(src, licenses / name, dirs_exist_ok=True)
revisions = {}
for name, repo in (("ports", root.parent), ("runtime", root.parent / "lindberghrecomp"), ("lifter", root.parent / "lindberghrecomp/pcrecomp")):
    revisions[name] = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
(out / "manifest.json").write_text(json.dumps({"revisions": revisions, "game_elf_sha256": args.elf_hash.read_text().strip(), "binaries": sorted(files.values(), key=lambda f: f["name"])}, indent=2) + "\n")
archive = shutil.make_archive(str(out), "zip", out.parent, out.name)
print(f"Packaged {len(files)} binaries in {out}; no game data included")
print(f"Archive: {archive}")
