#!/usr/bin/env python
"""Local stdio Model Context Protocol server for Ora customization and CSS Boosts."""

import argparse
import contextlib
import fcntl
import json
import os
import re
import sys
import tempfile
import uuid
from pathlib import Path

# Keep packaged resources immutable so running the server preserves app signing.
sys.dont_write_bytecode = True

PROTOCOLS = ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")


def valid_pattern(pattern):
    if not isinstance(pattern, str):
        return False
    if pattern == "*":
        return True
    host = pattern.removeprefix("*.")
    return (
        bool(re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", host))
        and ".." not in host
    )


class Store:
    def __init__(self, directory):
        self.directory = Path(directory).expanduser()
        self.path = self.directory / "boosts.json"

    def read(self):
        if not self.path.exists():
            return {"version": 1, "rules": []}
        document = json.loads(self.path.read_text())
        if document.get("version") != 1 or not isinstance(document.get("rules"), list):
            raise ValueError(
                "Unsupported or invalid Boost store. Existing data was preserved."
            )
        return document

    @contextlib.contextmanager
    def locked(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        with self.path.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def write(self, document):
        descriptor, temporary = tempfile.mkstemp(dir=self.directory, prefix=".boosts-")
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(document, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def call(self, name, arguments):
        if name == "import_arc_css_boosts":
            from arc_cache import css_rules

            source = (
                Path.home()
                / "Library/Application Support/firestore/Arc/bcny-arc-server/main"
            )
            rules, skipped = css_rules(source)
            accepted = [
                rule
                for rule in rules
                if valid_pattern(rule["pattern"])
                and len(rule["css"].encode()) <= 200_000
            ]
            skipped += len(rules) - len(accepted)
            with self.locked():
                document = self.read()
                existing = {rule["id"] for rule in document["rules"]}
                new_rules = [rule for rule in accepted if rule["id"] not in existing]
                document["rules"].extend(new_rules)
                self.write(document)
            return {
                "imported": len(new_rules),
                "enabled": sum(rule["enabled"] for rule in new_rules),
                "alreadyPresent": len(accepted) - len(new_rules),
                "skipped": skipped,
                "note": "Imported only custom CSS. Existing Ora edits and Arc enabled states were preserved.",
            }
        if name == "get_active_page":
            path = self.directory / "active-page.json"
            if not path.exists():
                return {
                    "activePage": None,
                    "note": "Open a regular Ora tab. Private tabs are not shared.",
                }
            return {
                "activePage": json.loads(path.read_text()),
                "note": "Check updatedAt; context may be stale if Ora is closed.",
            }
        if name == "list_css_boosts":
            return self.read()
        if name == "upsert_css_boost":
            pattern = arguments.get("pattern")
            css = arguments.get("css")
            title = arguments.get("name")
            if not valid_pattern(pattern):
                raise ValueError(
                    "Use a lowercase host, *.example.com, or * for all HTTP/HTTPS sites."
                )
            if not isinstance(css, str) or len(css.encode()) > 200_000:
                raise ValueError("CSS must be a string no larger than 200 KB.")
            if not isinstance(title, str) or not title.strip():
                raise ValueError("A nonempty name is required.")
            enabled = arguments.get("enabled", True)
            if not isinstance(enabled, bool):
                raise ValueError("enabled must be a boolean.")
            identifier = arguments.get("id") or str(uuid.uuid4())
            if not isinstance(identifier, str):
                raise ValueError("id must be a string.")
            rule = {
                "id": identifier,
                "name": title.strip(),
                "pattern": pattern,
                "css": css,
                "enabled": enabled,
            }
            with self.locked():
                document = self.read()
                document["rules"] = [
                    item for item in document["rules"] if item["id"] != identifier
                ] + [rule]
                self.write(document)
            return {
                "rule": rule,
                "note": "Saved persistently. Running Ora applies changes within about one second without reloading.",
            }
        if name == "delete_css_boost":
            identifier = arguments.get("id")
            if not isinstance(identifier, str):
                raise ValueError("A Boost id is required.")
            with self.locked():
                document = self.read()
                document["rules"] = [
                    item for item in document["rules"] if item["id"] != identifier
                ]
                self.write(document)
            return {"deleted": identifier}
        raise ValueError("Unknown tool")


def schema(properties=None, required=None):
    return {
        "type": "object",
        "properties": properties or {},
        "required": required or [],
        "additionalProperties": False,
    }


def tool(name, description, input_schema, read_only=False, destructive=False):
    return {
        "name": name,
        "description": description,
        "inputSchema": input_schema,
        "annotations": {
            "readOnlyHint": read_only,
            "destructiveHint": destructive,
            "openWorldHint": False,
        },
    }


TOOLS = [
    tool(
        "import_arc_css_boosts",
        "Import custom CSS Boosts from Arc's local cache. Reads a private copy of current database files, includes completed pending writes, and preserves enabled states. Does not import color-wheel settings. Existing imported ids are skipped to preserve Ora edits.",
        schema(),
    ),
    tool(
        "get_active_page",
        "Read the current regular Ora tab URL, host, and title. No page contents or private tabs are exposed.",
        schema(),
        True,
    ),
    tool(
        "list_css_boosts",
        "List saved CSS Boosts before editing. Reuse an existing id to update its CSS rather than duplicating it.",
        schema(),
        True,
    ),
    tool(
        "upsert_css_boost",
        "Save persistent CSS for a site. First inspect existing rules and the active page. Use its host for the current page; use *.example.com for a domain and subdomains, or * only when the user wants all sites. CSS applies live and on future navigations. This tool does not execute JavaScript.",
        schema(
            {
                "id": {"type": "string"},
                "name": {"type": "string"},
                "pattern": {"type": "string"},
                "css": {"type": "string"},
                "enabled": {"type": "boolean"},
            },
            ["name", "pattern", "css"],
        ),
    ),
    tool(
        "delete_css_boost",
        "Remove a saved CSS Boost by id and remove its live styles from Ora.",
        schema({"id": {"type": "string"}}, ["id"]),
        destructive=True,
    ),
]

PREFERENCE_TOOLS = [
    tool("list_settings_schema", "Discover every native setting, its type, default, allowed values, scope, and apply timing. Space keys replace {spaceId} with an id from get_settings.", schema(), True),
    tool("get_settings", "Read native browser preferences, revision, available spaces, and the app's last applied revision. Read before editing.", schema(), True),
    tool("update_settings", "Apply a validated atomic batch of persistent native settings. Use expectedRevision from get_settings. Theme and layout apply live. Website CSS uses the existing CSS Boost tools.", schema({"settings":{"type":"object"}, "expectedRevision":{"type":"integer"}}, ["settings"])),
    tool("preview_settings", "Validate a settings batch and return its changes without saving or changing Ora.", schema({"settings":{"type":"object"}, "expectedRevision":{"type":"integer"}}, ["settings"]), True),
    tool("reset_settings", "Reset only the named settings to catalog defaults. Undo remains available.", schema({"keys":{"type":"array","items":{"type":"string"}}, "expectedRevision":{"type":"integer"}}, ["keys"])),
    tool("undo_settings", "Undo the most recent native or MCP settings batch. Unrelated settings remain unchanged. History survives restarts.", schema({"expectedRevision":{"type":"integer"}})),
    tool("export_settings_profile", "Export a portable JSON settings profile. Optional keys select a theme-only or other subset. No passwords or page contents are included.", schema({"name":{"type":"string"}, "keys":{"type":"array","items":{"type":"string"}}}), True),
    tool("import_settings_profile", "Validate and apply an exported profile as one undoable settings batch. Existing settings not in the profile are preserved.", schema({"profile":{"type":"object"}, "expectedRevision":{"type":"integer"}}, ["profile"])),
]
TOOLS += PREFERENCE_TOOLS


def handle(request, store):
    identifier = request.get("id")
    if "id" not in request:
        return None
    method = request.get("method")
    params = request.get("params") or {}
    if method == "initialize":
        version = params.get("protocolVersion")
        result = {
            "protocolVersion": version if version in PROTOCOLS else "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "ora-css", "version": "0.2.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            name = params.get("name")
            target = store
            if name in {entry["name"] for entry in PREFERENCE_TOOLS}:
                from preferences import Preferences
                target = Preferences(store.directory.parent / "Customization")
            value = target.call(name, params.get("arguments") or {})
            result = {
                "content": [
                    {"type": "text", "text": json.dumps(value, ensure_ascii=False)}
                ],
                "isError": False,
            }
        except (ValueError, OSError, TypeError, IndexError) as error:
            result = {
                "content": [{"type": "text", "text": str(error)}],
                "isError": True,
            }
    else:
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "error": {"code": -32601, "message": "Method not found"},
        }
    return {"jsonrpc": "2.0", "id": identifier, "result": result}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--directory",
        default=str(
            Path.home()
            / "Library/Containers/io.github.kevinjohncutler.Ora.dev/Data/Library/Application Support/OraDev/Boosts"
        ),
    )
    args = parser.parse_args()
    store = Store(args.directory)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise TypeError("Expected a request object")
            response = handle(request, store)
        except (ValueError, TypeError, KeyError) as error:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": str(error)},
            }
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
