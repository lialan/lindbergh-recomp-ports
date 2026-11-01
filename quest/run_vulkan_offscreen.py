#!/usr/bin/env python3
"""Actual guest/Vulkan diagnostic, no Activity or OpenXR session.

Run the ENTIRE session through:
  python3 ~/.local/bin/quest3-lock python3 quest/run_vulkan_offscreen.py ...
No install, launch, wake, proximity, Guardian or app-data changes. Game assets
are copied into a unique private tree, including writable saves/config.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import time
import uuid

SERIAL="2G97C5ZJ0G02DQ"
PACKAGES=("org.lindbergh.hotd4sp.vr","org.lindbergh.hotd4sp.vr.vulkan")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir",type=Path,required=True)
    parser.add_argument("--shader-pack",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--pipeline-cache",type=Path,help="optional same-device cache from an earlier diagnostic")
    parser.add_argument("--prepare-timing",action="store_true",help="log native pipeline preparation time and creation counts")
    parser.add_argument("--timing-from",type=int,default=0)
    parser.add_argument("--game",default="/sdcard/HouseOfTheDead4Special")
    parser.add_argument("--frames",type=int,default=4)
    parser.add_argument("--timeout",type=int,default=60)
    parser.add_argument("--width",type=int,default=2064)
    parser.add_argument("--height",type=int,default=2280)
    parser.add_argument("--density",type=float,help="explicit constant FDM diagnostic, (0,1]")
    parser.add_argument("--dual",action="store_true")
    parser.add_argument("--menu",action="store_true")
    args=parser.parse_args()
    if not 2<=args.frames<=1000000 or not 1<=args.timeout<=600 or not 512<=args.width<=4096 or not 512<=args.height<=4096:
        parser.error("invalid frame, watchdog or target dimensions")
    if not 0<=args.timing_from<=args.frames-2:parser.error("invalid timing window")
    if args.density is not None and not 0<args.density<=1:parser.error("invalid constant density")
    if not args.game.startswith("/sdcard/"):parser.error("game source must be under /sdcard")
    root=Path(__file__).resolve().parents[1];build=args.build_dir.resolve();output=args.output.resolve()
    if output.exists() and any(output.iterdir()):parser.error("output must be fresh")
    cache=(build/"CMakeCache.txt").read_text()
    if "LINDBERGH_VULKAN_OFFSCREEN:BOOL=ON" not in cache or "LINDBERGH_OPENXR:BOOL=OFF" not in cache:
        parser.error("requires an explicitly offscreen, OpenXR-disabled build")
    deps=root.parent/"deps"
    files=[build/"hotd4sp_vulkan_offscreen",build/"libmain.so",deps/"sdl2-android/lib/libSDL2.so",deps/"openal-android/libopenal.so"]
    shaders={"game.lvsp":args.shader_pack.resolve(),"fixed.lvsp":build/"lindberghrecomp/src/renderer/vulkan/fixed-pack/fixed.lvsp"}
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    hashes.update({name:hashlib.sha256(p.read_bytes()).hexdigest() for name,p in shaders.items()})
    if args.pipeline_cache:hashes["initial_pipeline_cache"]=hashlib.sha256(args.pipeline_cache.read_bytes()).hexdigest()
    adb=str(Path.home()/"Library/Android/sdk/platform-tools/adb")
    remote="/data/local/tmp/lindbergh-offscreen-"+uuid.uuid4().hex
    executable=remote+"/hotd4sp_vulkan_offscreen"
    def command(*argv,timeout=25,check=True):
        return subprocess.run([adb,"-s",SERIAL,*map(str,argv)],capture_output=True,timeout=timeout,check=check)
    def shell(*argv,**kwargs):return command("shell",shlex.join(map(str,argv)),**kwargs)
    def baseline():
        result={}
        for package in PACKAGES:
            paths=shell("pm","path",package,check=False).stdout.decode().splitlines()
            result[package]={line.removeprefix("package:"):shell("sha256sum",line.removeprefix("package:")).stdout.decode().split()[0]
                             for line in paths if line.startswith("package:")}
        return result
    output.mkdir(parents=True,exist_ok=True)
    before=baseline();start=time.monotonic();errors=[]
    expected_elf=(root/"games/hotd4sp/generated/hod4M.elf.sha256").read_text().strip()
    env={"LD_LIBRARY_PATH":remote,"SDL_VIDEODRIVER":"dummy","SDL_AUDIODRIVER":"dummy","LINDBERGH_MUTE":"1","LINDBERGH_GL_THREAD":"1",
         "LINDBERGH_HIDDEN":"1","LINDBERGH_WINDOW":"640x480","LINDBERGH_EXIT_AFTER":str(args.frames),
         "LINDBERGH_AUTOSTART":"8","LINDBERGH_SHOT_FROM_GUN":"1","LINDBERGH_VULKAN_FAKE_YAW":"0",
         "LINDBERGH_VULKAN_FAKE_GUN":"2" if args.dual else "1",
         "LINDBERGH_XR_SET":f"width={args.width},resolution={args.height},dual={'on' if args.dual else 'off'},scale=1,screen=3,aim=15,hand=right,laser=laser,sight=none,crosshair=on,gun=on,hud_pitch=0,coins=auto,fps=off",
         "LINDBERGH_VULKAN_CACHE":remote+"/pipeline-cache.bin","LINDBERGH_NVRAM":remote+"/nvram.bin",
         "LINDBERGH_VULKAN_SHADERS":remote+"/game.lvsp","LINDBERGH_VULKAN_FIXED_SHADERS":remote+"/fixed.lvsp",
         "LINDBERGH_SHOT":remote+"/capture.ppm","LINDBERGH_SHOT_FRAME":str(args.frames-1),
         "LINDBERGH_FRAME_TIMINGS":remote+"/frames.csv","LINDBERGH_TIMING_FROM":str(args.timing_from),"LINDBERGH_TIMING_TO":str(args.frames-2)}
    if args.density is not None:env["LINDBERGH_VULKAN_OFFSCREEN_DENSITY"]=str(args.density)
    if args.prepare_timing:env["LINDBERGH_VULKAN_PREPARE_TIMING"]="1"
    if args.menu:env.update(LINDBERGH_VULKAN_FAKE_MENU="1",LINDBERGH_VULKAN_FAKE_MENU_LOOK="1")
    report={"serial":SERIAL,"scope":"Actual guest/shared Vulkan diagnostics; no XR, compositor or VR performance acceptance",
            "binary_hashes":hashes,"environment":env,"requested_frames":args.frames,"source":args.game,
            "build_options":{line.split(":",1)[0]:line.split("=",1)[1] for line in cache.splitlines()
                if "=" in line and line.split(":",1)[0] in ("CMAKE_BUILD_TYPE","CMAKE_C_FLAGS","CMAKE_C_FLAGS_RELEASE","CMAKE_CXX_FLAGS_RELEASE","ANDROID_ABI","ANDROID_PLATFORM","LINDBERGH_RENDERER","LINDBERGH_OPENXR","LINDBERGH_VULKAN_OFFSCREEN")}}
    ninja=(build/"build.ninja").read_text()
    match=re.search(r"build [^\n]*recomp_funcs_0000.c.o:[^\n]*\n((?:  [^\n]*\n)+)",ninja)
    if match:report["guest_compile"]={line.split(" = ",1)[0].strip():line.split(" = ",1)[1] for line in match[1].splitlines() if " = " in line and line.strip().startswith(("FLAGS =","DEFINES ="))}
    try:
        print("Locked offscreen session:",output,flush=True)
        source=args.game.rstrip("/")
        actual_elf=shell("sha256sum",source+"/elf/hod4M.elf").stdout.decode().split()[0]
        report["elf_sha256"]=actual_elf
        if actual_elf!=expected_elf:raise RuntimeError("Game ELF differs from the lifted input")
        for part in ("elf/hod4M.elf","fs"):
            shell("test","-r",source+"/"+part)
        if shell("find",source+"/elf",source+"/fs","-type","l").stdout.strip():
            raise RuntimeError("Source contains symlinks; cannot promise an independent copied game tree")
        available=shell("df","-k","/data/local/tmp").stdout.decode().splitlines()[-1].split()
        # Sum both directories; leave room for shaders, binaries, captures and saves.
        sizes=shell("du","-sk",source+"/elf",source+"/fs").stdout.decode().splitlines()
        source_kib=sum(int(line.split()[0]) for line in sizes)
        if int(available[3])<source_kib+512*1024:raise RuntimeError("Insufficient free space for private game copy")
        shell("mkdir","-p",remote+"/game")
        for part in ("elf","fs"):shell("cp","-R",source+"/"+part,remote+"/game/",timeout=180)
        for path in files:command("push",path,remote+"/"+path.name)
        for name,path in shaders.items():command("push",path,remote+"/"+name)
        if args.pipeline_cache:command("push",args.pipeline_cache,remote+"/pipeline-cache.bin")
        shell("chmod","700",executable)
        script=output/"run.sh"
        script.write_text("set -eu\ncd "+shlex.quote(remote+"/game/elf")+"\n"+
                          "echo $$ > "+shlex.quote(remote+"/pid")+"\n"+
                          "exec "+shlex.join(["env",*[k+"="+v for k,v in env.items()],executable,"hod4M.elf"])+"\n")
        command("push",script,remote+"/run.sh")
        with (output/"game.log").open("wb") as log:
            process=subprocess.Popen([adb,"-s",SERIAL,"shell",shlex.join(["timeout","-s","KILL",str(args.timeout),"sh",remote+"/run.sh"])],stdout=log,stderr=subprocess.STDOUT)
            try:process.wait(timeout=args.timeout+25)
            except subprocess.TimeoutExpired:
                report["host_watchdog"]=True;process.kill();process.wait()
        text=(output/"game.log").read_text(errors="replace")
        reached=[int(n) for n in re.findall(r"LINDBERGH_EXIT_AFTER: (\d+) frames done",text)]
        report.update(exit_code=process.returncode,reached_frame_limit=bool(reached and max(reached)>=args.frames))
        for name in ("capture.ppm","capture.right.ppm","frames.csv","pipeline-cache.bin"):
            command("pull",remote+"/"+name,output/name,check=False)
        report["artifacts"]={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file() and p.name.endswith((".ppm",".csv"))}
        report["eye_images"]={}
        for name in ("capture.ppm","capture.right.ppm"):
            image=output/name
            if image.exists():
                magic,dimensions,maximum,pixels=image.read_bytes().split(b"\n",3)
                valid=(magic==b"P6" and dimensions==f"{args.width} {args.height}".encode() and maximum==b"255" and len(pixels)==args.width*args.height*3)
                report["eye_images"][name]={"valid":valid,"nonzero_components":sum(v!=0 for v in pixels),"values":len(set(pixels))}
        report["stereo_capture_valid"]=(len(report["eye_images"])==2 and all(r["valid"] and r["values"]>1 for r in report["eye_images"].values()) and
            report["artifacts"].get("capture.ppm")!=report["artifacts"].get("capture.right.ppm"))
        print("\n".join(text.splitlines()[-35:]),flush=True)
    except Exception as error:
        report["execution_error"]=repr(error)
        raise
    finally:
        try:
            pid=shell("cat",remote+"/pid",check=False).stdout.strip()
            if pid.isdigit():
                process=command("exec-out","cat","/proc/"+pid.decode()+"/cmdline",check=False).stdout.split(b"\0",1)[0]
                if process==executable.encode():shell("kill","-KILL",pid.decode())
            shell("rm","-rf","--",remote)
        except Exception as error:errors.append(str(error))
        try:
            after=baseline();report["baseline_after"]=after
            if after!=before:errors.append("Installed APK hashes changed during diagnostic")
        except Exception as error:errors.append(str(error))
        report.update(elapsed_seconds=time.monotonic()-start,baseline_before=before,cleanup_errors=errors)
        (output/"report.json").write_text(json.dumps(report,indent=2)+"\n")
        if errors:raise RuntimeError("; ".join(errors))
        print("Private tree cleaned; installed APKs unchanged; lock releases on wrapper exit.",flush=True)
    return 0 if report.get("exit_code")==0 and report.get("reached_frame_limit") and report.get("stereo_capture_valid") else 1

if __name__=="__main__":raise SystemExit(main())
