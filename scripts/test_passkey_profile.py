import datetime
import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("passkey_profile", Path(__file__).with_name("check-passkey-profile.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


@pytest.fixture
def profile():
    return {
        "UUID": "10000000-0000-0000-0000-000000000001",
        "TeamIdentifier": ["SYNTHETIC"],
        "ExpirationDate": datetime.datetime(2030, 1, 1),
        "Entitlements": {
            "com.apple.application-identifier": "SYNTHETIC.org.example.browser",
            "com.apple.developer.web-browser.public-key-credential": True,
        },
    }


def test_requires_matching_browser_profile(profile):
    assert module.validate(profile, "SYNTHETIC", "org.example.browser") == profile["UUID"]
    with pytest.raises(ValueError, match="another signing team"):
        module.validate(profile, "OTHERTEAM", "org.example.browser")
    with pytest.raises(ValueError, match="exact browser identifier"):
        module.validate(profile, "SYNTHETIC", "org.example.other")


@pytest.mark.parametrize("capability", [False, None, "true", 1])
def test_missing_or_invalid_capability_is_rejected(profile, capability):
    profile["Entitlements"]["com.apple.developer.web-browser.public-key-credential"] = capability
    with pytest.raises(ValueError, match="does not authorize native browser passkeys"):
        module.validate(profile, "SYNTHETIC", "org.example.browser")


def test_expired_profile_is_rejected(profile):
    with pytest.raises(ValueError, match="expired"):
        module.validate(profile, "SYNTHETIC", "org.example.browser", datetime.datetime(2031, 1, 1, tzinfo=datetime.timezone.utc))
