import importlib.util
import struct
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "arc_cache.py"
spec = importlib.util.spec_from_file_location("arc_cache", MODULE)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def integer(value):
    data = bytearray()
    while value > 127:
        data.append((value & 127) | 128)
        value >>= 7
    data.append(value)
    return bytes(data)


def field(number, data):
    return integer(number * 8 + 2) + integer(len(data)) + data


def document(css, active="true"):
    def entry(key, text):
        return field(2, field(1, key.encode()) + field(2, field(17, text.encode())))

    import json

    value = field(1, b"projects/example/databases/main/documents/boosts/fixture")
    value += entry("data", json.dumps({"css": css}))
    value += entry("hostPattern", "*.example.com")
    value += entry("title", "Dark")
    value += entry("isActive", active)
    return field(2, value)


def record(payload):
    return b"\0" * 4 + len(payload).to_bytes(2, "little") + b"\x01" + payload


def batch(sequence, data):
    key = b"remote/boosts/fixture"
    value = integer(len(key)) + key
    kind = b"\x00" if data is None else b"\x01"
    if data is not None:
        value += integer(len(data)) + data
    return struct.pack("<QI", sequence, 1) + kind + value


def test_complete_write_ahead_updates_and_tombstones(tmp_path):
    (tmp_path / "CURRENT").write_text("MANIFEST-000001\n")
    (tmp_path / "MANIFEST-000001").write_bytes(record(integer(2) + integer(2)))
    log = tmp_path / "000002.log"
    log.write_bytes(
        record(batch(1, document("body{color:red}")))
        + record(batch(2, document("body{color:gray}", "false")))
        + b"unfinished"
    )
    rules, skipped = cache.css_rules(tmp_path)
    assert skipped == 0
    assert len(rules) == 1
    assert rules[0]["css"] == "body{color:gray}"
    assert rules[0]["enabled"] is False
    assert rules[0]["pattern"] == "*.example.com"
    log.write_bytes(log.read_bytes()[:-10] + record(batch(3, None)))
    assert cache.css_rules(tmp_path)[0] == []


def test_snappy_literals_and_overlapping_copies():
    assert cache.snappy(b"\x05\x00a\x01\x01") == b"aaaaa"


def test_manifest_tracks_deleted_tables():
    def added(number):
        return (
            integer(7)
            + integer(0)
            + integer(number)
            + integer(100)
            + integer(1)
            + b"a"
            + integer(1)
            + b"z"
        )

    deleted = integer(6) + integer(0) + integer(3)
    manifest = record(added(3) + integer(2) + integer(4)) + record(deleted + added(5))
    assert cache.live_files(manifest) == ({5}, 4, 0)
