#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

xcodegen generate >/dev/null
xcodebuild \
  -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager \
  -destination 'platform=macOS,arch=arm64' \
  build

echo
echo "Built app:"
echo "$HOME/Library/Developer/Xcode/DerivedData/AgentSessionManager-*/Build/Products/Debug/AgentSessionManager.app"
