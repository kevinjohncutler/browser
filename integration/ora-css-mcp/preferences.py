"""Shared, typed browser preferences with atomic updates and bounded undo history."""

import base64
import copy
import json
import math
import re
import uuid
from pathlib import Path

from server import Store


def schema_path():
    bundled = Path(__file__).with_name("settings-schema.json")
    return bundled if bundled.exists() else Path(__file__).resolve().parents[2] / "ora/Resources/settings-schema.json"


def validate(value, schema, label):
    kind = ("null" if value is None else "boolean" if isinstance(value, bool) else
            "integer" if isinstance(value, int) or (isinstance(value, float) and math.isfinite(value) and value.is_integer()) else "number" if isinstance(value, float) else
            "string" if isinstance(value, str) else "array" if isinstance(value, list) else
            "object" if isinstance(value, dict) else "invalid")
    types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
    if kind not in types and not (kind == "integer" and "number" in types):
        raise ValueError(f"{label}: expected {types}, received {kind}")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError(f"{label}: choose from {schema['enum']}")
    if kind in ("integer", "number"):
        if not math.isfinite(value) or value < schema.get("minimum", -math.inf) or value > schema.get("maximum", math.inf):
            raise ValueError(f"{label}: number is outside the allowed range")
    if kind == "string":
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", 200000):
            raise ValueError(f"{label}: invalid string length")
        if schema.get("contentEncoding") == "base64":
            try:
                base64.b64decode(value, validate=True)
            except (ValueError, TypeError):
                raise ValueError(f"{label}: invalid base64 data")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise ValueError(f"{label}: expected {schema['pattern']}")
    if kind == "array":
        if len(value) > schema.get("maxItems", 1000):
            raise ValueError(f"{label}: too many items")
        if schema.get("uniqueItemIDs") and len({item.get("id") for item in value if isinstance(item, dict)}) != len(value):
            raise ValueError(f"{label}: item IDs must be unique")
        if any(isinstance(item, dict) and item.get("id") in schema.get("forbiddenItemIDs", []) for item in value):
            raise ValueError(f"{label}: reserved item ID")
        for index, item in enumerate(value):
            validate(item, schema["items"], f"{label}[{index}]")
    if kind == "object":
        if len(value) > schema.get("maxProperties", 1000) or any(key not in value for key in schema.get("required", [])):
            raise ValueError(f"{label}: missing required fields or too many properties")
        for key, item in value.items():
            if "propertyNames" in schema:
                validate(key, schema["propertyNames"], label)
            if schema.get("mapKeyField") and (not isinstance(item, dict) or item.get(schema["mapKeyField"]) != key):
                raise ValueError(f"{label}: map key does not match item field")
            child = schema.get("properties", {}).get(key, schema.get("additionalProperties", False))
            if not child:
                raise ValueError(f"{label}: unknown property {key}")
            if isinstance(child, dict):
                validate(item, child, f"{label}.{key}")


class Preferences(Store):
    def __init__(self, directory):
        super().__init__(directory)
        self.path = self.directory / "preferences.json"
        self.definitions = json.loads(schema_path().read_text())["settings"]

    @staticmethod
    def canonical_key(key):
        if key.startswith("space."):
            parts = key.split(".")
            try:
                parts[1] = str(uuid.UUID(parts[1])).upper()
            except (ValueError, IndexError):
                raise ValueError(f"Invalid space setting: {key}")
            return ".".join(parts)
        return key

    def canonical_patch(self, patch):
        self.validate_patch(patch)
        result = {self.canonical_key(key): value for key, value in patch.items()}
        if len(result) != len(patch):
            raise ValueError("Duplicate space setting aliases")
        return result

    def definition(self, key):
        for entry in self.definitions:
            if entry["id"] == key:
                return entry
            if entry["scope"] == "space" and re.fullmatch(
                    re.escape(entry["id"]).replace(r"\{spaceId\}", r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"), key):
                return entry
        raise ValueError(f"Unknown setting: {key}. Read list_settings_schema first.")

    def read(self):
        if not self.path.exists():
            return {"version": 1, "revision": 0, "values": {}, "history": []}
        if self.path.stat().st_size > 4_000_000:
            raise ValueError("Settings file is too large")
        document = json.loads(self.path.read_text())
        if document.get("version") != 1 or type(document.get("revision")) is not int or document["revision"] < 0 or not isinstance(document.get("history"), list):
            raise ValueError("Invalid preferences. Existing data was preserved.")
        if len(document["history"]) > 50:
            raise ValueError("Too much settings history")
        document["values"] = self.canonical_patch(document.get("values"))
        for entry in document["history"]:
            if not isinstance(entry, dict) or not isinstance(entry.get("label"), str):
                raise ValueError("Invalid settings history")
            entry["before"] = self.canonical_patch(entry.get("before"))
        return document

    def validate_patch(self, patch):
        if not isinstance(patch, dict) or len(patch) > 1000:
            raise ValueError("settings must be an object with at most 1000 entries")
        for key, value in patch.items():
            validate(value, self.definition(key)["schema"], key)

    def effective(self, document):
        result = {entry["id"]: copy.deepcopy(entry["schema"]["default"]) for entry in self.definitions if entry["scope"] == "global"}
        result.update(document["values"])
        return result

    def update(self, patch, expected=None, preview=False, label="MCP update"):
        patch = self.canonical_patch(patch)
        with self.locked():
            document = self.read()
            if expected is not None and expected != document["revision"]:
                raise ValueError("Preferences changed since they were read. Read get_settings and retry.")
            current = self.effective(document)
            changes = {key: value for key, value in patch.items() if value != current.get(key, self.definition(key)["schema"]["default"])}
            before = {key: current.get(key, self.definition(key)["schema"]["default"]) for key in changes}
            if changes and not preview:
                document["history"] = (document["history"] + [{"label": label, "before": before}])[-50:]
                document["values"].update(changes)
                document["revision"] += 1
                self.write(document)
            return {"revision": document["revision"], "preview": preview, "changes": changes,
                    "apply": {key: self.definition(key)["apply"] for key in changes},
                    "note": "Live settings apply within one second while Ora runs. Navigation and launch settings report their application timing."}

    def write(self, document):
        if len(json.dumps(document, ensure_ascii=False, allow_nan=False).encode()) > 4_000_000:
            raise ValueError("Settings and undo history exceed the size limit")
        super().write(document)

    def call(self, name, arguments):
        if name == "list_settings_schema":
            return {"version": 1, "settings": self.definitions}
        if name == "get_settings":
            document = self.read()
            status = self.directory / "app-status.json"
            spaces = self.directory / "spaces.json"
            return {"revision": document["revision"], "settings": self.effective(document),
                    "app": json.loads(status.read_text()) if status.exists() else None,
                    "spaces": json.loads(spaces.read_text()) if spaces.exists() else [],
                    "note": "Check the app timestamp and appliedRevision. Saved changes can wait until Ora starts."}
        if name in ("update_settings", "preview_settings"):
            return self.update(arguments.get("settings"), arguments.get("expectedRevision"), name == "preview_settings")
        if name == "reset_settings":
            keys = arguments.get("keys")
            if not isinstance(keys, list) or not keys:
                raise ValueError("Supply a nonempty list of setting keys to reset")
            return self.update({key: self.definition(key)["schema"]["default"] for key in keys}, arguments.get("expectedRevision"), label="Reset settings")
        if name == "undo_settings":
            with self.locked():
                document = self.read()
                expected = arguments.get("expectedRevision")
                if expected is not None and expected != document["revision"]:
                    raise ValueError("Preferences changed. Read get_settings and retry.")
                if not document["history"]:
                    raise ValueError("No settings changes to undo")
                entry = document["history"][-1]
                self.validate_patch(entry["before"])
                document["history"].pop()
                document["values"].update(entry["before"])
                document["revision"] += 1
                self.write(document)
            return {"revision": document["revision"], "restored": entry["before"], "label": entry["label"]}
        if name == "export_settings_profile":
            document = self.read()
            keys = arguments.get("keys")
            values = self.effective(document)
            if keys is not None:
                values = {key: values.get(key, self.definition(key)["schema"]["default"]) for key in keys}
            return {"version": 1, "name": arguments.get("name", "Ora profile"), "values": values}
        if name == "import_settings_profile":
            profile = arguments.get("profile", {})
            if profile.get("version") != 1:
                raise ValueError("Unsupported settings profile")
            return self.update(profile.get("values"), arguments.get("expectedRevision"), label="Import profile")
        raise ValueError("Unknown preferences tool")
