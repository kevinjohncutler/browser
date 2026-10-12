#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export ORA_BUILD_SPEC=project.browser.yml
export ORA_NATIVE_PASSKEY_BUILD_SPEC=project.browser-passkeys.yml
export ORA_BUILD_BUNDLE_ID=io.github.kevinjohncutler.browser
export ORA_DERIVED_DATA_PATH="${ORA_BROWSER_REVIEW_DERIVED_DATA_PATH:-$HOME/Library/Caches/ora-browser-review-build}"
exec bash "$repo_dir/scripts/build-dev.sh"
