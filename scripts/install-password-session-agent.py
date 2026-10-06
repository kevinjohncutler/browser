#!/usr/bin/env python
"""Install the signed, local background session at the stable development app path."""

import argparse
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


def install(app):
    app = app.resolve(strict=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    label = info["CFBundleIdentifier"] + ".PasswordSession"
    program = app / "Contents/XPCServices/PasswordBridge.xpc/Contents/MacOS/PasswordBridge"
    if not program.is_file():
        raise ValueError("The signed app does not include the password bridge.")
    directory = Path.home() / "Library/LaunchAgents"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (label + ".plist")
    document = {
        "Label": label,
        "ProgramArguments": [str(program), "--session-agent"],
        "MachServices": {label: True},
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Background",
        "KeepAlive": {"SuccessfulExit": False},
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".ora-password-session-")
    try:
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(document, stream)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    domain = f"gui/{os.getuid()}"
    existing = subprocess.run(["/bin/launchctl", "print", f"{domain}/{label}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if existing.returncode:
        subprocess.run(["/bin/launchctl", "bootstrap", domain, str(path)], check=True)
    # Preserve a live authenticated session when updating the app. Never boot it out here.
    print(f"Background Apple Passwords session installed: {path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    install(parser.parse_args().app)
