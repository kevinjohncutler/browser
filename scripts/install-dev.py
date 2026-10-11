#!/usr/bin/env python
"""Install a signed development build at a stable path without launching or quitting it."""

import argparse
import datetime
import os
import plistlib
import subprocess
import uuid
from pathlib import Path


def verify(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def install(source, destination):
    source = source.resolve(strict=True)
    destination = destination.expanduser().absolute()
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if not info.get("CFBundleIdentifier", "").endswith(".dev"):
        raise ValueError("Install only a signed development build with a .dev identifier.")
    if source == destination:
        raise ValueError("The build source and installation path must be different.")
    verify(source)
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
    args = parser.parse_args()
    install(args.source, args.destination)
