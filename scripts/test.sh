#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_CACHE="$HOME/Library/Caches/com.xiaopomao.LGLidSwitch/SwiftModuleCache"
mkdir -p "$TASK_CACHE"
TEST_BINARY="$(mktemp -t lglidswitch-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$TASK_CACHE" Sources/Model.swift Sources/Engine.swift Tests/EngineTests.swift -o "$TEST_BINARY"
"$TEST_BINARY"
