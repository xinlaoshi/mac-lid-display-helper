#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="/Applications/Mac合盖和显示器联动助手.app"
AGENT="$HOME/Library/LaunchAgents/com.xiaopomao.LGLidSwitch.plist"
if [[ ! -x 'output/Mac合盖和显示器联动助手.app/Contents/MacOS/LGLidSwitch' ]]; then bash scripts/build.sh; fi
launchctl bootout "gui/$(id -u)/com.xiaopomao.LGLidSwitch" 2>/dev/null || true
python3 - "$APP/Contents/MacOS/LGLidSwitch" <<'PY'
import os,signal,subprocess,sys,time
target=sys.argv[1]
def running():
    result=[]
    for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
        columns=line.strip().split(None,1)
        if len(columns)==2 and columns[1]==target:result.append(int(columns[0]))
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
ditto 'output/Mac合盖和显示器联动助手.app' "$APP"
touch "$APP"
TASK_LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
if [[ -x "$TASK_LSREGISTER" ]]; then "$TASK_LSREGISTER" -f "$APP" || true; fi
python3 - "$AGENT" "$APP/Contents/MacOS/LGLidSwitch" <<'PY'
import sys,plistlib
from pathlib import Path
p=Path(sys.argv[1]);p.parent.mkdir(parents=True,exist_ok=True)
v={'Label':'com.xiaopomao.LGLidSwitch','ProgramArguments':[sys.argv[2]],'RunAtLoad':True,'ProcessType':'Interactive','LimitLoadToSessionType':'Aqua'}
p.write_bytes(plistlib.dumps(v))
PY
launchctl enable "gui/$(id -u)/com.xiaopomao.LGLidSwitch"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl print "gui/$(id -u)/com.xiaopomao.LGLidSwitch"
