#!/usr/bin/env python3
"""Bounded Vulkan/OpenXR APK check for any game; run ENTIRE script under quest3-lock.

Only updates/stops the experimental .vulkan package. Copies game assets into
a unique app-internal directory, removes that copy after use, streams fresh
all-buffer logcat and retains session evidence. No Guardian/tracking changes.
"""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
import time
import uuid
from pathlib import Path

SERIAL="2G97C5ZJ0G02DQ"

def game_conf(root,game):
    """games/<game>/game.conf is shell; read the variables the runner needs."""
    script='. "$1"; printf "%s\\0" "$PKG" "$ACTIVITY" "$HEADSET_DIR" "${HEADSET_SUB:-}" "$GAME_PARTS" "$ELF" "$SHA_FILE" "${LOG:-}"'
    values=subprocess.run(["bash","-c",script,"conf",str(root/"games"/game/"game.conf")],capture_output=True,check=True).stdout.decode().split("\0")
    keys=("PKG","ACTIVITY","HEADSET_DIR","HEADSET_SUB","GAME_PARTS","ELF","SHA_FILE","LOG")
    return dict(zip(keys,values))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game",default="hotd4sp",help="a games/<game> module (default hotd4sp)")
    parser.add_argument("--apk",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--seconds",type=int,default=70)
    parser.add_argument("--interactive",action="store_true",
                        help="normal play for a person: no autoplay/exit/diagnostics; runs until the app exits or OUTPUT/STOP exists")
    parser.add_argument("--set",action="append",default=[],metavar="KEY=VALUE",help="override/add one game environment entry")
    args=parser.parse_args()
    if not args.interactive and not 10<=args.seconds<=150:parser.error("watchdog must be 10..150 seconds")
    root=Path(__file__).resolve().parents[1]
    conf=game_conf(root,args.game)
    ORIGINAL=conf["PKG"];PACKAGE=ORIGINAL+".vulkan";ACTIVITY=conf["ACTIVITY"]
    ELF=conf["ELF"];PARTS=conf["GAME_PARTS"].split()
    LOG=conf["LOG"] or args.game+".log" # the runtime's log beside the game (GSE: gse.log)
    sdk=Path.home()/"Library/Android/sdk"
    aapt=sorted((sdk/"build-tools").glob("*/aapt2"))[-1]
    badging=subprocess.run([str(aapt),"dump","badging",str(args.apk.resolve())],capture_output=True,text=True,check=True).stdout
    if not re.search(r"^package: name='"+re.escape(PACKAGE)+r"'",badging,re.M):parser.error("requires the isolated .vulkan APK")
    out=args.output.resolve()
    if out.exists() and any(out.iterdir()):parser.error("output must be fresh")
    out.mkdir(parents=True,exist_ok=True)
    adb=str(Path.home()/"Library/Android/sdk/platform-tools/adb")
    own="/sdcard/Android/data/"+PACKAGE+"/files"
    source=conf["HEADSET_DIR"]+("/"+conf["HEADSET_SUB"] if conf["HEADSET_SUB"] else "")
    token=uuid.uuid4().hex;private=None
    report={"serial":SERIAL,"token":token,"apk_sha256":hashlib.sha256(args.apk.read_bytes()).hexdigest(),
            "scope":"Actual game/OpenXR session; physical aiming/display/combat acceptance remains separate"}
    cleanup=[];proximity=False;launched=False;stream=None;installed=False;workspace_created=False
    def command(*argv,check=True,timeout=30):
        return subprocess.run([adb,"-s",SERIAL,*map(str,argv)],capture_output=True,check=check,timeout=timeout)
    def shell(*argv,**kwargs):return command("shell",shlex.join(map(str,argv)),**kwargs)
    def save(name,result):
        (out/name).write_bytes(result.stdout+result.stderr)
        return result
    def apk_hashes(package):
        paths=shell("pm","path",package,check=False).stdout.decode().splitlines()
        return {p[8:]:shell("sha256sum",p[8:]).stdout.decode().split()[0] for p in paths if p.startswith("package:")}
    def exists(path):
        return shell("ls","-d",path,check=False).returncode==0
    def original_files():
        result={}
        # "." (GSE copies its whole folder) is the app's own files directory,
        # which the app creates itself: not a file the runner must restore.
        for name in ("env.txt",LOG,"HOW-TO-ADD-THE-GAME.txt",ELF,*[p for p in PARTS if p not in (ELF.split("/")[0],".")]):
            path=own+"/"+name
            if not exists(path):result[name]=None
            elif shell("test","-f",path,check=False).returncode==0:
                result[name]=shell("sha256sum",path).stdout.decode().split()[0]
            else:result[name]="directory"
        return result
    before=apk_hashes(ORIGINAL);report["original_apk_before"]=before
    report["experimental_apk_before"]=apk_hashes(PACKAGE)
    original=original_files();report["original_files_before"]=original
    try:
        print("Locked headed session:",out,flush=True)
        expected=(root/"games"/args.game/"generated"/conf["SHA_FILE"]).read_text().strip()
        actual=shell("sha256sum",source+"/"+ELF).stdout.decode().split()[0]
        if expected!=actual:raise RuntimeError("source ELF differs from lifted input")
        report["elf_sha256"]=actual
        if shell("find",*[source+"/"+p for p in PARTS],"-type","l").stdout.strip():raise RuntimeError("independent staging requires no source symlinks")
        available=int(shell("df","-k","/sdcard").stdout.decode().splitlines()[-1].split()[3])
        size=sum(int(line.split()[0]) for line in shell("du","-sk",*[source+"/"+p for p in PARTS]).stdout.decode().splitlines())
        if available<size+512*1024:raise RuntimeError("insufficient space for private app game copy")
        save("install.txt",command("install","-r",args.apk.resolve(),timeout=90));installed=True
        report["experimental_apk_after_install"]=apk_hashes(PACKAGE)
        if report["apk_sha256"] not in report["experimental_apk_after_install"].values():raise RuntimeError("installed APK hash mismatch")
        # The UUID workspace is app-owned internal storage. External storage
        # staged by shell is inaccessible to the APK on current Quest firmware.
        shell("am","force-stop",PACKAGE)
        app_home=shell("run-as",PACKAGE,"pwd").stdout.decode().strip()
        private=app_home+"/files/.codex-xr-"+token
        report["private_game_directory"]=private
        # The game's folder goes where the app looks under its base (HOTD4:
        # the base itself; GSE: vsg_l/), and runs from the executable's folder.
        stage=private+("/"+conf["HEADSET_SUB"] if conf["HEADSET_SUB"] else "")
        game_dir=stage+("/"+ELF.rsplit("/",1)[0] if "/" in ELF else "")
        report["game_directory"]=game_dir
        shell("run-as",PACKAGE,"mkdir","-p",stage)
        workspace_created=True
        transfer=shlex.join(["tar","-C",source,"-cf","-",*PARTS])+" | "+shlex.join(["run-as",PACKAGE,"tar","-C",stage,"-xf","-"])
        save("stage.txt",command("shell",transfer,timeout=180))
        env={"LINDBERGH_AUTOSTART":"8","LINDBERGH_AUTOGUN":"2","LINDBERGH_MUTE":"1","LINDBERGH_GL_THREAD":"1",
             "LINDBERGH_EXIT_AFTER":"3600",
             "LINDBERGH_VULKAN_CACHE":private+"/pipelines.bin","LINDBERGH_NVRAM":private+"/nvram.bin",
             "LINDBERGH_FRAME_TIMINGS":private+"/frames.csv","LINDBERGH_TIMING_FROM":"0","LINDBERGH_TIMING_TO":"3598",
             "LINDBERGH_VULKAN_SUBMISSION_TIMINGS":private+"/submissions.csv","LINDBERGH_VULKAN_PREPARE_TIMING":"1",
             "LINDBERGH_VULKAN_COMMAND_STATS":"1","LINDBERGH_VULKAN_STATE_FILTER":"1","LINDBERGH_VULKAN_INDEX_REUSE":"1",
             "LINDBERGH_SHOT":private+"/capture.ppm","LINDBERGH_SHOT_FRAME":"120"}
        if args.interactive:
            env={"LINDBERGH_GL_THREAD":"1","LINDBERGH_VULKAN_CACHE":private+"/pipelines.bin","LINDBERGH_NVRAM":private+"/nvram.bin"}
        for item in args.set:
            key,_,value=item.partition("=")
            if not key or not _:raise RuntimeError("--set requires KEY=VALUE")
            env[key]=value.replace("{private}",private)
        report["environment"]=env
        # XR settings come from the player's staged elf/vr.cfg, as in the GL
        # app; --set LINDBERGH_XR_SET=... remains available for one-off runs.
        cfg=shell("run-as",PACKAGE,"cat",game_dir+"/vr.cfg",check=False)
        report["vr_cfg"]=cfg.stdout.decode(errors="replace") if cfg.returncode==0 else None
        (out/"vr.cfg").write_bytes(cfg.stdout if cfg.returncode==0 else b"")
        envfile=out/"env.txt";envfile.write_text("\n".join(k+"="+v for k,v in env.items())+"\n")
        for destination in (private+"/env.txt",game_dir+"/env.txt"):
            with envfile.open("rb") as config:
                subprocess.run([adb,"-s",SERIAL,"shell","run-as "+PACKAGE+" sh -c "+shlex.quote("cat > "+shlex.quote(destination))],stdin=config,capture_output=True,check=True,timeout=30)
        # Fail before Activity launch when the app UID cannot read staged
        # files. The Activity independently enforces this in its actual context.
        probe=save("app-uid-access.txt",shell("run-as",PACKAGE,"sha256sum",stage+"/"+ELF,game_dir+"/env.txt",check=False))
        hashes=[line.split()[0] for line in probe.stdout.decode().splitlines() if line.split()]
        if probe.returncode or hashes != [expected,hashlib.sha256(envfile.read_bytes()).hexdigest()]:
            raise RuntimeError("app UID cannot verify staged ELF/env; refusing shared-path fallback")
        report["device_time"]=shell("date").stdout.decode().strip()
        logfile=(out/"logcat-all.txt").open("wb")
        stream=subprocess.Popen([adb,"-s",SERIAL,"logcat","-b","all","-v","threadtime","-T","1"],stdout=logfile,stderr=subprocess.STDOUT)
        # logcat attaches asynchronously. Wait until the marker is actually
        # retained before launch, rather than losing it to the -T 1 race.
        for attempt in range(20):
            shell("log","-t","LindberghXRSession","START "+token)
            time.sleep(.2)
            if "START "+token in (out/"logcat-all.txt").read_text(errors="replace"):break
        else:raise RuntimeError("fresh logcat marker was not observed; refusing untracked launch")
        proximity=True;save("proximity-close.txt",shell("am","broadcast","-a","com.oculus.vrpowermanager.prox_close"))
        shell("input","keyevent","KEYCODE_WAKEUP")
        # Observe process/session state ourselves. am start -W may wait on
        # system focus/Activity transitions instead of the requested app.
        launched=True;save("launch.txt",shell("am","start","-n",PACKAGE+"/"+ACTIVITY,"--ez","lindbergh.require_private_game","true","--es","lindbergh.private_game",private))
        start=time.monotonic();pid=""
        stop=out/"STOP"
        if args.interactive:print("Interactive session running; create",stop,"to end it",flush=True)
        while args.interactive or time.monotonic()-start<args.seconds:
            if args.interactive and stop.exists():break
            if subprocess.run([adb,"-s",SERIAL,"get-state"],capture_output=True,timeout=10).returncode:
                # Unplugged (e.g. played untethered): not an app exit. An
                # interactive session waits for the cable; a bounded one ends.
                report["device_disconnected"]=True
                if not args.interactive:break
                time.sleep(2);continue
            current=shell("pidof",PACKAGE,check=False).stdout.decode().strip()
            if current and not pid:pid=current.split()[0];report["pid"]=pid
            if pid and not current:report["early_process_exit"]=True;break
            time.sleep(1)
        save("process.txt",shell("ps","-A","-o","PID,NAME,ARGS",check=False))
        save("activity.txt",shell("dumpsys","activity","activities",check=False))
        save("exit-info.txt",shell("dumpsys","activity","exit-info",PACKAGE,check=False))
        for name in (LOG,"capture.ppm","frames.csv","submissions.csv","passes.csv","pipelines.bin.recipes"):
            # exec-out can return zero for a remote cat error; do not save
            # error text as an image, CSV or binary pipeline recipe file.
            if shell("run-as",PACKAGE,"test","-f",private+"/"+name,check=False).returncode:
                report.setdefault("missing_artifacts",[]).append(name)
                continue
            result=command("exec-out","run-as",PACKAGE,"cat",private+"/"+name,check=False)
            if result.returncode==0:(out/("game.log" if name==LOG else name)).write_bytes(result.stdout)
        with (out/"screen.png").open("wb") as picture:
            subprocess.run([adb,"-s",SERIAL,"exec-out","screencap","-p"],stdout=picture,check=True,timeout=20)
    except Exception as error:
        report["execution_error"]=repr(error);raise
    finally:
        if args.interactive and (launched or installed):
            print("Waiting for the headset to reconnect for cleanup...",flush=True)
            subprocess.run([adb,"-s",SERIAL,"wait-for-device"],check=False)
        if launched or installed:
            try:save("stop.txt",shell("am","force-stop",PACKAGE))
            except Exception as error:cleanup.append("stop: "+repr(error))
        if proximity:
            try:save("proximity-restore.txt",shell("am","broadcast","-a","com.oculus.vrpowermanager.automation_disable"))
            except Exception as error:cleanup.append("proximity: "+repr(error))
        if stream:
            stream.terminate()
            try:stream.wait(timeout=10)
            except subprocess.TimeoutExpired:stream.kill();stream.wait()
            logfile.close()
        # Delete only the unique internal workspace. Existing external game
        # files are never relocated or selected by this diagnostic.
        try:
            if workspace_created and not cleanup:shell("run-as",PACKAGE,"rm","-rf",private)
        except Exception as error:cleanup.append("restore: "+repr(error))
        try:
            after=apk_hashes(ORIGINAL);report["original_apk_after"]=after
            if before!=after:cleanup.append("original GL APK changed")
            # A launch without the private-game extras (the system relaunching
            # the app after a disconnect) writes its log into the app's own
            # folder: this run's artifact, kept in OUTPUT and removed there.
            if original.get(LOG) is None and exists(own+"/"+LOG):
                save("relaunch-"+LOG,command("exec-out","cat",own+"/"+LOG,check=False))
                shell("rm","-f",own+"/"+LOG,check=False)
            restored=original_files();report["original_files_after"]=restored
            if restored!=original:cleanup.append("experimental app files were not restored exactly")
        except Exception as error:cleanup.append("original APK verification: "+repr(error))
        report["cleanup_errors"]=cleanup
        (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
        print("Headed session cleanup:",cleanup or "complete; original GL APK unchanged",flush=True)
        if cleanup:raise RuntimeError("; ".join(cleanup))
    raw=(out/"logcat-all.txt").read_text(errors="replace")
    marker="START "+token
    fresh=raw[raw.find(marker):] if marker in raw else ""
    pid=report.get("pid","")
    # Threadtime PID filtering only, independent of Android ring-buffer history.
    lines=[line for line in fresh.splitlines() if pid and re.match(r"^\d\d-\d\d\s+\S+\s+"+re.escape(pid)+r"\s+",line)]
    (out/"logcat-pid.txt").write_text("\n".join(lines)+"\n")
    report["fresh_log_marker"]=bool(fresh)
    expected_dir=report.get("game_directory","")
    selected=[line.split("[android] game directory ",1)[1].strip() for line in lines if "[android] game directory " in line]
    normalize=lambda path:path.replace("/storage/emulated/0/","/sdcard/")
    report["private_game_selected"]=bool(selected) and all(normalize(path)==expected_dir for path in selected)
    report["app_private_game_verified"]=any("private game verified:" in line for line in lines)
    report["xr_session_states"]=[int(match.group(1)) for line in lines
                                  if (match:=re.search(r"\[vulkan-xr\] session state (\d+)",line))]
    report["focused_observed"]=5 in report["xr_session_states"]
    report["performance_accepted"]=False
    report["startup_evidence"]=[line for line in lines if any(k in line for k in ("vulkan-xr","vulkan-recipes","first game target","vulkan-offscreen","Fatal signal","AndroidRuntime"))]
    (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print("\n".join(report["startup_evidence"][-35:]),flush=True)
    # A successful collector is not an XR/performance acceptance verdict.
    return 0 if all(report.get(k) for k in ("pid","fresh_log_marker","private_game_selected","app_private_game_verified")) else 1

if __name__=="__main__":raise SystemExit(main())
