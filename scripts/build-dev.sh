#!/bin/bash
set -euo pipefail

: "${ORA_DEVELOPMENT_TEAM:?Set ORA_DEVELOPMENT_TEAM to your Apple Developer team identifier}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${ORA_DERIVED_DATA_PATH:-$HOME/Library/Caches/ora-dev-build}"
cd "$repo_dir"
project_spec="${ORA_BUILD_SPEC:-project.dev.yml}"
bundle_identifier="${ORA_BUILD_BUNDLE_ID:-io.github.kevinjohncutler.Ora.dev}"
if [ "${ORA_REQUIRE_NATIVE_PASSKEYS:-0}" = "1" ] && [ -z "${ORA_PASSKEY_PROVISIONING_PROFILE:-}" ]; then
  printf '%s\n' 'Native Apple passkeys require an approved provisioning profile. No native-enabled build was produced.' >&2
  exit 1
fi
if [ -n "${ORA_PASSKEY_PROVISIONING_PROFILE:-}" ]; then
  ORA_PASSKEY_PROFILE_UUID="$(python -S scripts/check-passkey-profile.py "$ORA_PASSKEY_PROVISIONING_PROFILE" \
    --team "$ORA_DEVELOPMENT_TEAM" --bundle "$bundle_identifier")"
  export ORA_PASSKEY_PROFILE_UUID
  profile_directory="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$profile_directory"
  install -m 600 "$ORA_PASSKEY_PROVISIONING_PROFILE" "$profile_directory/$ORA_PASSKEY_PROFILE_UUID.provisionprofile"
  project_spec="${ORA_NATIVE_PASSKEY_BUILD_SPEC:-project.native-passkeys.yml}"
fi
build_days="$(( ($(date +%s) - 1577836800) / 86400 ))"
build_number="$build_days.$(date -u +%H).$(date -u +%M)"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_revision="$(git describe --always --dirty)"
xcodegen generate --spec "$project_spec"
xcodebuild -project Ora.xcodeproj -scheme ora -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS,arch=arm64' \
  CURRENT_PROJECT_VERSION="$build_number" ORA_DEV_BUILD_DATE="$build_date" \
  ORA_DEV_BUILD_REVISION="$build_revision" build
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$derived_data/Build/Products/Debug/OraDev.app/Contents/Info.plist")"
if [ "$actual_identifier" != "$bundle_identifier" ]; then
  printf '%s\n' 'The built browser identifier does not match the requested signing identity.' >&2
  exit 1
fi
touch "$derived_data/Build/Products/Debug/OraDev.app"
printf 'Built app: %s/Build/Products/Debug/OraDev.app\n' "$derived_data"
