#!/usr/bin/env python
"""Validate a native browser passkey profile without requesting credentials or Apple approval."""

import argparse
import datetime
import plistlib
import subprocess
import uuid
from pathlib import Path


def validate(profile, team, bundle, now=None):
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("com.apple.developer.web-browser.public-key-credential") is not True:
        raise ValueError("The profile does not authorize native browser passkeys.")
    if team not in profile.get("TeamIdentifier", []):
        raise ValueError("The profile belongs to another signing team.")
    if entitlements.get("com.apple.application-identifier") != f"{team}.{bundle}":
        raise ValueError("The profile does not authorize this exact browser identifier.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        raise ValueError("The profile has no valid expiration date.")
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= (now or datetime.datetime.now(datetime.timezone.utc)):
        raise ValueError("The native browser passkey profile has expired.")
    return str(uuid.UUID(profile.get("UUID", "")))


def read_profile(path):
    result = subprocess.run(
        ["/usr/bin/security", "cms", "-D", "-i", str(path)], capture_output=True, check=True
    )
    return plistlib.loads(result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle", required=True)
    args = parser.parse_args()
    try:
        print(validate(read_profile(args.profile), args.team, args.bundle))
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        # CMS contents are signing metadata, but never dump them or subprocess output.
        parser.exit(1, "Native passkey signing profile rejected: " + (
            str(error) if isinstance(error, ValueError) else "Cannot decode the profile."
        ) + "\n")
