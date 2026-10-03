#!/bin/bash
set -euo pipefail

: "${ORA_DEVELOPMENT_TEAM:?Set ORA_DEVELOPMENT_TEAM to your Apple Developer team identifier}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${ORA_DERIVED_DATA_PATH:-$HOME/Library/Caches/ora-dev-build}"
cd "$repo_dir"
xcodegen generate --spec project.dev.yml
xcodebuild -project Ora.xcodeproj -scheme ora -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS,arch=arm64' build
printf 'Built app: %s/Build/Products/Debug/OraDev.app\n' "$derived_data"
