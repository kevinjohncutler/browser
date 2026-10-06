import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from preferences import Preferences
from server import Store, handle


def test_schema_defaults_and_atomic_validation(tmp_path):
    store = Preferences(tmp_path)
    schema = store.call("list_settings_schema", {})
    assert len(schema["settings"]) == 60
    for definition in schema["settings"]:
        key = definition["id"].replace("{spaceId}", "11111111-1111-1111-1111-111111111111")
        store.validate_patch({key: definition["schema"]["default"]})
    store.update({"theme.rowHeight": 42, "theme.dark.background": "#202020"})
    original = store.path.read_bytes()
    for bad in [True, 100, "40", float("nan")]:
        with pytest.raises(ValueError):
            store.update({"theme.rowHeight": bad, "toolbar.hidden": True})
        assert store.path.read_bytes() == original
    with pytest.raises(ValueError):
        store.update({"unknown": True})
    with pytest.raises(ValueError):
        store.update({"shortcuts.overrides": {"test": {"characterString": "ab", "modifiers": 16}}})
    with pytest.raises(ValueError):
        store.update({"privacy.filterLists": [{"id": "same"}, {"id": "same"}]})


def test_preview_revision_undo_reset_and_profiles(tmp_path):
    store = Preferences(tmp_path)
    result = store.call("preview_settings", {"settings": {"theme.rowHeight": 48}})
    assert result["changes"] == {"theme.rowHeight": 48}
    assert not store.path.exists()
    store.update({"theme.rowHeight": 48, "toolbar.hidden": True}, expected=0)
    profile = store.call("export_settings_profile", {"name": "Roomy", "keys": ["theme.rowHeight", "toolbar.hidden"]})
    reopened = Preferences(tmp_path)
    with pytest.raises(ValueError):
        reopened.update({"theme.rowHeight": 32}, expected=0)
    reopened.call("reset_settings", {"keys": ["theme.rowHeight", "toolbar.hidden"]})
    reopened.call("import_settings_profile", {"profile": profile})
    assert reopened.effective(reopened.read())["theme.rowHeight"] == 48
    reopened.call("undo_settings", {})
    assert reopened.effective(reopened.read())["theme.rowHeight"] == 34
    reopened.call("undo_settings", {})
    assert reopened.effective(reopened.read())["toolbar.hidden"] is True


def test_tool_dispatch_context_and_space_aliases(tmp_path):
    store = Store(tmp_path / "Boosts")
    message = {"id": 1, "method": "tools/call", "params": {"name": "update_settings", "arguments": {
        "settings": {"space.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.name": "Work"}}}}
    assert not handle(message, store)["result"]["isError"]
    preferences = Preferences(tmp_path / "Customization")
    assert preferences.read()["values"] == {"space.AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.name": "Work"}
    with pytest.raises(ValueError):
        preferences.update({"space.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.name": "One",
                            "space.AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.name": "Two"})
    (preferences.directory / "app-status.json").write_text(json.dumps({"appliedRevision": 1}))
    assert preferences.call("get_settings", {})["app"]["appliedRevision"] == 1


def test_concurrent_updates_and_history_bound(tmp_path):
    store = Preferences(tmp_path)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda n: store.update({"theme.rowHeight": 26 + n % 39}), range(60)))
    doc = store.read()
    assert len(doc["history"]) == 50
    assert doc["revision"] >= 50
    for bad in ["broken", '{"version":1,"revision":true,"values":{},"history":[]}']:
        store.path.write_text(bad)
        with pytest.raises(ValueError):
            store.update({"theme.rowHeight": 40})
        assert store.path.read_text() == bad
