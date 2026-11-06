#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="/Applications/Mac合盖和显示器联动助手.app"
AGENT="$HOME/Library/LaunchAgents/com.xiaopomao.LGLidSwitch.plist"
if [[ ! -x 'output/Mac合盖和显示器联动助手.app/Contents/MacOS/MacDisplaySwitch' ]]; then bash scripts/build.sh; fi
INSTALL_STAGE="$(mktemp -d /Applications/.MacDisplaySwitch.XXXXXX)"
cleanup_install_stage() {
    if [[ -d "$INSTALL_STAGE/previous.app" && ! -e "$APP" ]]; then
        echo "Previous app retained for recovery: $INSTALL_STAGE/previous.app" >&2
    else
        rm -rf "$INSTALL_STAGE"
    fi
}
trap cleanup_install_stage EXIT
ditto 'output/Mac合盖和显示器联动助手.app' "$INSTALL_STAGE/new.app"
codesign --verify --strict "$INSTALL_STAGE/new.app"
launchctl bootout "gui/$(id -u)/com.xiaopomao.LGLidSwitch" 2>/dev/null || true
python3 - "$APP/Contents/MacOS/LGLidSwitch" "$APP/Contents/MacOS/MacDisplaySwitch" <<'PY'
import os,signal,subprocess,sys,time
targets=set(sys.argv[1:])
def running():
    result=[]
    for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
        columns=line.strip().split(None,1)
        if len(columns)==2 and columns[1] in targets:result.append(int(columns[0]))
    return result
# LaunchServices may start an instance outside this LaunchAgent. Stop only the
# verified installed executable, so the single-instance guard cannot retain old code.
for pid in running():
    try:os.kill(pid,signal.SIGTERM)
    except ProcessLookupError:pass
deadline=time.monotonic()+5
while running() and time.monotonic()<deadline:time.sleep(.1)
if running():raise SystemExit('Installed app is still running; replacement cancelled')
PY
# Replace the complete bundle; overlay copying would retain the old executable
# and invalidate the new signature after the internal executable rename.
if [[ -d "$APP" ]]; then mv "$APP" "$INSTALL_STAGE/previous.app"; fi
if ! mv "$INSTALL_STAGE/new.app" "$APP"; then
    if [[ -d "$INSTALL_STAGE/previous.app" ]]; then mv "$INSTALL_STAGE/previous.app" "$APP"; fi
    exit 1
fi
touch "$APP"
TASK_LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
if [[ -x "$TASK_LSREGISTER" ]]; then "$TASK_LSREGISTER" -f "$APP" || true; fi
python3 - "$AGENT" "$APP/Contents/MacOS/MacDisplaySwitch" <<'PY'
import sys,plistlib
from pathlib import Path
p=Path(sys.argv[1]);p.parent.mkdir(parents=True,exist_ok=True)
v={'Label':'com.xiaopomao.LGLidSwitch','ProgramArguments':[sys.argv[2]],'RunAtLoad':True,'ProcessType':'Interactive','LimitLoadToSessionType':'Aqua'}
p.write_bytes(plistlib.dumps(v))
PY
launchctl enable "gui/$(id -u)/com.xiaopomao.LGLidSwitch"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl print "gui/$(id -u)/com.xiaopomao.LGLidSwitch"
