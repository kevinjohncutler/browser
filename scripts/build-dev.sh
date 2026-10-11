#!/bin/bash
set -euo pipefail

: "${ORA_DEVELOPMENT_TEAM:?Set ORA_DEVELOPMENT_TEAM to your Apple Developer team identifier}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${ORA_DERIVED_DATA_PATH:-$HOME/Library/Caches/ora-dev-build}"
cd "$repo_dir"
build_days="$(( ($(date +%s) - 1577836800) / 86400 ))"
build_number="$build_days.$(date -u +%H).$(date -u +%M)"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_revision="$(git describe --always --dirty)"
xcodegen generate --spec project.dev.yml
xcodebuild -project Ora.xcodeproj -scheme ora -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS,arch=arm64' \
  CURRENT_PROJECT_VERSION="$build_number" ORA_DEV_BUILD_DATE="$build_date" \
  ORA_DEV_BUILD_REVISION="$build_revision" build
touch "$derived_data/Build/Products/Debug/OraDev.app"
printf 'Built app: %s/Build/Products/Debug/OraDev.app\n' "$derived_data"
