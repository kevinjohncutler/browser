#!/usr/bin/env python
"""Install a signed development build at a stable path without launching or quitting it."""

import argparse
import datetime
import importlib.util
import os
import plistlib
import subprocess
import uuid
from pathlib import Path


def verify(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def verify_native_passkeys(source, required=False):
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(source)], capture_output=True, check=True
    )
    data = result.stdout + result.stderr
    start, end = data.find(b"<?xml"), data.find(b"</plist>")
    entitlements = plistlib.loads(data[start:end + 8])
    authorized = entitlements.get("com.apple.developer.web-browser.public-key-credential") is True
    if required and not authorized:
        raise ValueError("The app lacks native Apple passkey signing authorization. Nothing was installed.")
    if authorized:
        spec = importlib.util.spec_from_file_location("passkey_profile", Path(__file__).with_name("check-passkey-profile.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        profile = module.read_profile(source / "Contents/embedded.provisionprofile")
        info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
        module.validate(profile, entitlements.get("com.apple.developer.team-identifier"), info["CFBundleIdentifier"])


def install(source, destination, require_native_passkeys=False):
    source = source.resolve(strict=True)
    destination = destination.expanduser().absolute()
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if not info.get("CFBundleIdentifier", "").endswith(".dev"):
        raise ValueError("Install only a signed development build with a .dev identifier.")
    if source == destination:
        raise ValueError("The build source and installation path must be different.")
    verify(source)
    verify_native_passkeys(source, required=require_native_passkeys)
    destination.parent.mkdir(parents=True, exist_ok=True)
    nonce = uuid.uuid4().hex
    stage = destination.parent / ("OraDev-stage-" + nonce + ".app")
    backup = Path.home() / "Library/Caches" / ("OraDev-before-install-" + nonce + ".app")
    backup.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/ditto", str(source), str(stage)], check=True)
    # ditto preserves the old bundle directory dates, even when its executable is new.
    # Update only unsigned directory metadata, leaving all signed bundle contents intact.
    tool = subprocess.check_output(["/usr/bin/xcrun", "--find", "SetFile"], text=True).strip()
    created = datetime.datetime.now().strftime("%m/%d/%Y %H:%M:%S")
    subprocess.run([tool, "-d", created, str(stage)], check=True)
    os.utime(stage, None)
    verify(stage)
    had_previous = destination.exists()
    if had_previous:
        destination.rename(backup)
    try:
        stage.rename(destination)
        verify(destination)
    except Exception:
        if destination.exists():
            destination.rename(stage)
        if had_previous:
            backup.rename(destination)
        raise
    print(f"Installed: {destination}")
    print(f"Build: {info.get('CFBundleVersion', 'unknown')}")
    print(f"Revision: {info.get('OraBuildRevision', 'unknown')}")
    if had_previous:
        print(f"Previous bundle: {backup}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications/OraDev.app")
    parser.add_argument("--require-native-passkeys", action="store_true")
    args = parser.parse_args()
    install(args.source, args.destination, args.require_native_passkeys)
