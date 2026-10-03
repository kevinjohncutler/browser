#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
: "${1:?Pass the installed Apple Passwords extension folder containing manifest.json}"
installation_dir="${ORA_APPLE_PASSWORDS_DIRECTORY:-$HOME/Library/Containers/io.github.kevinjohncutler.Ora.dev/Data/Library/Application Support/OraDev/Extensions/ApplePasswords}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ora-password-installer.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -swift-version 5 \
  "$repo_dir/ora/Features/Passwords/Extensions/NativePasswordMessaging.swift" \
  "$repo_dir/ora/Features/Passwords/Extensions/ApplePasswordCompatibility.swift" \
  "$repo_dir/ora/Features/Passwords/Extensions/ApplePasswordExtensionInstaller.swift" \
  "$repo_dir/integration/ora-passwords/InstallerMain.swift" \
  -o "$work_dir/installer"
"$work_dir/installer" "$1" "$installation_dir"
