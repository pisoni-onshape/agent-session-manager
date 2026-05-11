#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

state_dir=".build-state"
counter_file="$state_dir/release-version-counter"
release_glob="$HOME/Library/Developer/Xcode/DerivedData/AgentSessionManager-*/Build/Products/Release/AgentSessionManager.app"
install_app="/Applications/AgentSessionManager.app"
install_cli_link="/usr/local/bin/agent-session-manager"
ci_package_only=false
artifacts_dir=""
build_counter_override="${BUILD_COUNTER_OVERRIDE:-}"
marketing_version_override="${MARKETING_VERSION_OVERRIDE:-}"

usage() {
  cat <<'EOF'
Usage: ./build.sh [--ci-package] [--output-dir DIR]

Options:
  --ci-package      Build the Release app and package it as a zip without installing it.
  --output-dir DIR  Directory for the packaged zip when --ci-package is used.

Environment overrides:
  BUILD_COUNTER_OVERRIDE       Use this numeric build counter instead of .build-state/release-version-counter.
  MARKETING_VERSION_OVERRIDE   Use this marketing version instead of the default counter+commit derived version.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci-package)
      ci_package_only=true
      ;;
    --output-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --output-dir." >&2
        usage >&2
        exit 1
      fi
      artifacts_dir="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$ci_package_only" != true && -n "$artifacts_dir" ]]; then
  echo "--output-dir can only be used together with --ci-package." >&2
  exit 1
fi

if [[ -n "$build_counter_override" && ! "$build_counter_override" =~ ^[0-9]+$ ]]; then
  echo "BUILD_COUNTER_OVERRIDE must be numeric." >&2
  exit 1
fi

persist_counter=true
if [[ "$ci_package_only" == true || -n "$build_counter_override" ]]; then
  persist_counter=false
fi

current_counter=0
if [[ -z "$build_counter_override" && -f "$counter_file" ]]; then
  current_counter="$(tr -d '[:space:]' < "$counter_file")"
fi

if [[ -n "$build_counter_override" ]]; then
  next_counter="$build_counter_override"
else
  next_counter=$((current_counter + 1))
fi

commit_hex="$(git rev-parse --short=8 HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if [[ -z "$commit_hex" ]]; then
  commit_hex="00000000"
fi
commit_digits="$(printf '%08d' "$((16#$commit_hex % 100000000))")"
marketing_version="${marketing_version_override:-${next_counter}.${commit_digits}}"

xcodegen generate >/dev/null
xcodebuild \
  -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CURRENT_PROJECT_VERSION="$next_counter" \
  MARKETING_VERSION="$marketing_version" \
  build

if [[ "$persist_counter" == true ]]; then
  mkdir -p "$state_dir"
  printf '%s\n' "$next_counter" > "$counter_file"
fi

shopt -s nullglob
release_candidates=( $release_glob )
shopt -u nullglob
release_app=""
release_mtime=0
for candidate in "${release_candidates[@]}"; do
  candidate_mtime="$(stat -f '%m' "$candidate")"
  if [[ -z "$release_app" || "$candidate_mtime" -gt "$release_mtime" ]]; then
    release_app="$candidate"
    release_mtime="$candidate_mtime"
  fi
done

if [[ -z "$release_app" ]]; then
  echo "Release app bundle not found after build." >&2
  exit 1
fi

if [[ "$ci_package_only" == true ]]; then
  artifacts_dir="${artifacts_dir:-build/artifacts}"
  mkdir -p "$artifacts_dir"
  packaged_app="$artifacts_dir/AgentSessionManager-${marketing_version}.zip"
  rm -f "$packaged_app"
  ditto -c -k --sequesterRsrc --keepParent "$release_app" "$packaged_app"

  echo
  echo "Built Release app:"
  echo "$release_app"
  echo
  echo "Packaged artifact:"
  echo "$packaged_app"
  echo
  echo "Marketing version:"
  echo "$marketing_version"
  exit 0
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
installed_cli_helper="$install_app/Contents/Helpers/AgentSessionManagerCLI"
if [[ ! -x "$installed_cli_helper" ]]; then
  echo "Bundled CLI helper not found at $installed_cli_helper." >&2
  exit 1
fi

install_cli_link_copy() {
  mkdir -p "$(dirname "$install_cli_link")"
  ln -sfn "$installed_cli_helper" "$install_cli_link"
}

if [[ -w "$(dirname "$install_cli_link")" ]]; then
  install_cli_link_copy
else
  echo "Installing the CLI helper to /usr/local/bin may require administrator privileges."
  sudo mkdir -p "$(dirname "$install_cli_link")"
  sudo ln -sfn "$installed_cli_helper" "$install_cli_link"
fi

echo "Installed CLI link:"
echo "$install_cli_link"
echo
echo "Marketing version:"
echo "$marketing_version"
