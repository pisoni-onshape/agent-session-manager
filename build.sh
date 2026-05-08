#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

state_dir=".build-state"
counter_file="$state_dir/release-version-counter"
release_glob="$HOME/Library/Developer/Xcode/DerivedData/AgentSessionManager-*/Build/Products/Release/AgentSessionManager.app"
install_app="/Applications/AgentSessionManager.app"

mkdir -p "$state_dir"

current_counter=0
if [[ -f "$counter_file" ]]; then
  current_counter="$(tr -d '[:space:]' < "$counter_file")"
fi

next_counter=$((current_counter + 1))
commit_hex="$(git rev-parse --short=8 HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if [[ -z "$commit_hex" ]]; then
  commit_hex="00000000"
fi
commit_digits="$(printf '%08d' "$((16#$commit_hex % 100000000))")"
marketing_version="${next_counter}.${commit_digits}"

xcodegen generate >/dev/null
xcodebuild \
  -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CURRENT_PROJECT_VERSION="$next_counter" \
  MARKETING_VERSION="$marketing_version" \
  build

printf '%s\n' "$next_counter" > "$counter_file"

release_app="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Build/Products/Release/AgentSessionManager.app' -print -quit)"
if [[ -z "$release_app" ]]; then
  echo "Release app bundle not found after build." >&2
  exit 1
fi

running_pids="$(
  ps -axo pid=,command= |
    awk '$0 ~ /\/Applications\/AgentSessionManager.app\/Contents\/MacOS\/AgentSessionManager/ { print $1 }'
)"
if [[ -n "$running_pids" ]]; then
  for pid in $running_pids; do
    kill -9 "$pid"
  done
  sleep 1
fi

install_copy() {
  rm -rf "$install_app"
  ditto "$release_app" "$install_app"
}

if [[ -d "$install_app" ]]; then
  install_parent="$install_app"
else
  install_parent="/Applications"
fi

if [[ -w "$install_parent" ]]; then
  install_copy
else
  echo "Installing to /Applications requires administrator privileges."
  sudo rm -rf "$install_app"
  sudo ditto "$release_app" "$install_app"
fi

/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$install_app" >/dev/null 2>&1 || true

echo
echo "Built Release app:"
echo "$release_app"
echo
echo "Installed app:"
echo "$install_app"
echo
echo "Marketing version:"
echo "$marketing_version"
