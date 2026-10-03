import importlib.util
import json
import subprocess
import sys
from pathlib import Path

SERVER = Path(__file__).resolve().parents[1] / "server.py"
spec = importlib.util.spec_from_file_location("ora_css_server", SERVER)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def test_stdio_roundtrip_and_persistence(tmp_path):
    messages = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-06-18"},
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "upsert_css_boost",
                "arguments": {
                    "id": "sample",
                    "name": "Dark",
                    "pattern": "*.example.com",
                    "css": "body { background:#171717; }",
                },
            },
        },
    ]
    process = subprocess.run(
        [sys.executable, str(SERVER), "--directory", str(tmp_path)],
        input="".join(json.dumps(message) + "\n" for message in messages),
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    assert [response["id"] for response in responses] == [1, 2, 3]
    assert responses[0]["result"]["capabilities"] == {"tools": {}}
    assert len(responses[1]["result"]["tools"]) == 5
    assert not responses[2]["result"]["isError"]
    reopened = server.Store(tmp_path)
    assert reopened.read()["rules"][0]["pattern"] == "*.example.com"
    reopened.call(
        "upsert_css_boost",
        {
            "id": "sample",
            "name": "Edited",
            "pattern": "example.com",
            "css": "p{color:red}",
        },
    )
    assert len(reopened.read()["rules"]) == 1
    reopened.call("delete_css_boost", {"id": "sample"})
    assert reopened.read()["rules"] == []


def test_rejects_invalid_scope_and_preserves_corrupt_store(tmp_path):
    store = server.Store(tmp_path)
    message = {
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "upsert_css_boost",
            "arguments": {"name": "Bad", "pattern": "*example.com", "css": "body{}"},
        },
    }
    assert server.handle(message, store)["result"]["isError"]
    store.path.write_text("broken")
    message["params"]["arguments"]["pattern"] = "example.com"
    assert server.handle(message, store)["result"]["isError"]
    assert store.path.read_text() == "broken"


def test_regular_page_context_and_missing_private_context(tmp_path):
    store = server.Store(tmp_path)
    assert store.call("get_active_page", {})["activePage"] is None
    context = {
        "host": "example.com",
        "url": "https://example.com",
        "updatedAt": "2026-01-01T00:00:00Z",
    }
    (tmp_path / "active-page.json").write_text(json.dumps(context))
    assert store.call("get_active_page", {})["activePage"] == context


def test_protocol_negotiation_and_errors(tmp_path):
    store = server.Store(tmp_path)
    response = server.handle(
        {"id": 1, "method": "initialize", "params": {"protocolVersion": "unsupported"}},
        store,
    )
    assert response["result"]["protocolVersion"] == "2025-06-18"
    assert server.handle({"method": "notifications/initialized"}, store) is None
    assert (
        server.handle({"id": 2, "method": "unknown"}, store)["error"]["code"] == -32601
    )
