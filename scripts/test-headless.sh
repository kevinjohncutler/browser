#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${ORA_TEST_DERIVED_DATA_PATH:-$HOME/Library/Caches/ora-headless-tests}"
cd "$repo_dir"
xcodegen generate --spec project.dev.yml
export TEST_RUNNER_ORA_HEADLESS_TESTING=1
if [ -n "${ORA_PREVIEW_DIRECTORY:-}" ]; then
  export TEST_RUNNER_ORA_PREVIEW_DIRECTORY="$ORA_PREVIEW_DIRECTORY"
fi
xcodebuild -project Ora.xcodeproj -scheme ora -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test "$@"
