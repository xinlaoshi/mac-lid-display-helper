#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/output/Mac合盖和显示器联动助手.app"
TASK_CACHE="$HOME/Library/Caches/com.xiaopomao.LGLidSwitch/SwiftModuleCache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TASK_CACHE"
if [[ ! -f assets/AppIcon.icns || assets/AppIcon.png -nt assets/AppIcon.icns ]]; then bash scripts/make-icon.sh; fi
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/support/wechat-appreciation-code.png "$APP/Contents/Resources/AppreciationCode.png"
cp assets/support/wechat-official-account.jpg "$APP/Contents/Resources/WeChatOfficialAccount.jpg"
cp assets/support/author-avatar.png "$APP/Contents/Resources/AuthorAvatar.png"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -module-cache-path "$TASK_CACHE" -framework AppKit -framework SwiftUI -framework IOKit Sources/*.swift -o "$APP/Contents/MacOS/LGLidSwitch"
python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
app=Path(sys.argv[1])
p={'CFBundleExecutable':'LGLidSwitch','CFBundleIdentifier':'com.xiaopomao.LGLidSwitch','CFBundleName':'Mac合盖和显示器联动助手','CFBundleDisplayName':'Mac合盖和显示器联动助手','CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.2.6','CFBundleVersion':'13','CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSHighResolutionCapable':True}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(p,f)
PY
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
