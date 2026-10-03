"""Read Arc's local Firestore cache without opening or modifying its database."""

import json
import shutil
import struct
import tempfile
from pathlib import Path


def varint(data, pos=0):
    value = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
        shift += 7


def snappy(data):
    size, pos = varint(data)
    out = bytearray()
    while pos < len(data):
        tag = data[pos]
        pos += 1
        kind = tag & 3
        if kind == 0:
            n = tag >> 2
            if n >= 60:
                count = n - 59
                n = int.from_bytes(data[pos : pos + count], "little")
                pos += count
            n += 1
            out += data[pos : pos + n]
            pos += n
        else:
            if kind == 1:
                n = 4 + ((tag >> 2) & 7)
                offset = ((tag & 224) << 3) | data[pos]
                pos += 1
            else:
                n = 1 + (tag >> 2)
                count = 2 if kind == 2 else 4
                offset = int.from_bytes(data[pos : pos + count], "little")
                pos += count
            for _ in range(n):
                out.append(out[-offset])
    assert len(out) == size
    return bytes(out)


def block(data, offset, size):
    raw = data[offset : offset + size]
    return snappy(raw) if data[offset + size] == 1 else raw


def entries(raw):
    count = int.from_bytes(raw[-4:], "little")
    end = len(raw) - 4 - count * 4
    pos = 0
    key = b""
    while pos < end:
        shared, pos = varint(raw, pos)
        unshared, pos = varint(raw, pos)
        size, pos = varint(raw, pos)
        key = key[:shared] + raw[pos : pos + unshared]
        pos += unshared
        value = raw[pos : pos + size]
        pos += size
        yield key, value


def table(data):
    footer = data[-48:]
    _, pos = varint(footer)
    _, pos = varint(footer, pos)
    offset, pos = varint(footer, pos)
    size, pos = varint(footer, pos)
    for _, handle in entries(block(data, offset, size)):
        offset, pos = varint(handle)
        size, pos = varint(handle, pos)
        yield from entries(block(data, offset, size))


def proto(data):
    pos = 0
    fields = []
    while pos < len(data):
        tag, pos = varint(data, pos)
        wire = tag & 7
        num = tag >> 3
        if wire == 0:
            value, pos = varint(data, pos)
        elif wire == 1:
            value = struct.unpack("<d", data[pos : pos + 8])[0]
            pos += 8
        elif wire == 2:
            size, pos = varint(data, pos)
            value = data[pos : pos + size]
            pos += size
        elif wire == 5:
            value = data[pos : pos + 4]
            pos += 4
        else:
            raise ValueError(wire)
        fields.append((num, value))
    return fields


def value(data):
    fields = proto(data)
    if not fields:
        return None
    num, v = fields[0]
    if num == 17:
        return v.decode()
    if num == 1:
        return bool(v)
    if num in (2, 3):
        return v
    if num == 11:
        return {
            proto(entry)[0][1].decode(): value(proto(entry)[1][1])
            for _, entry in proto(v)
        }
    if num == 9:
        return [value(item) for _, item in proto(v)]
    return None


def records(data):
    """Reassemble complete LevelDB log records, ignoring an unfinished tail."""
    position = 0
    fragments = bytearray()
    while position + 7 <= len(data):
        remaining = 32768 - position % 32768
        if remaining < 7:
            position += remaining
            continue
        size = int.from_bytes(data[position + 4 : position + 6], "little")
        kind = data[position + 6]
        if kind == 0 and size == 0:
            position += remaining
            continue
        if size + 7 > remaining or position + 7 + size > len(data):
            break
        payload = data[position + 7 : position + 7 + size]
        position += 7 + size
        if kind == 1:
            yield payload
        elif kind == 2:
            fragments = bytearray(payload)
        elif kind == 3:
            fragments.extend(payload)
        elif kind == 4:
            fragments.extend(payload)
            yield bytes(fragments)
            fragments.clear()


def live_files(manifest):
    tables = set()
    log_number = 0
    previous_log = 0
    for record in records(manifest):
        position = 0
        while position < len(record):
            tag, position = varint(record, position)
            if tag in (1,):
                size, position = varint(record, position)
                position += size
            elif tag in (2, 3, 4, 9):
                number, position = varint(record, position)
                if tag == 2:
                    log_number = number
                elif tag == 9:
                    previous_log = number
            elif tag == 5:
                _, position = varint(record, position)
                size, position = varint(record, position)
                position += size
            elif tag == 6:
                _, position = varint(record, position)
                number, position = varint(record, position)
                tables.discard(number)
            elif tag == 7:
                _, position = varint(record, position)
                number, position = varint(record, position)
                _, position = varint(record, position)
                for _ in range(2):
                    size, position = varint(record, position)
                    position += size
                tables.add(number)
            else:
                raise ValueError("Unsupported database manifest")
    return tables, log_number, previous_log


def batch_entries(record):
    sequence = int.from_bytes(record[:8], "little")
    count = int.from_bytes(record[8:12], "little")
    position = 12
    for index in range(count):
        kind = record[position]
        position += 1
        size, position = varint(record, position)
        key = record[position : position + size]
        position += size
        data = None
        if kind == 1:
            size, position = varint(record, position)
            data = record[position : position + size]
            position += size
        elif kind != 0:
            raise ValueError("Unsupported database batch")
        yield key, sequence + index, data


def read_boosts(root):
    root = Path(root)
    with tempfile.TemporaryDirectory(prefix="ora-arc-css-") as temporary:
        snapshot = Path(temporary)
        manifest_name = (root / "CURRENT").read_text().strip()
        if Path(manifest_name).name != manifest_name or not manifest_name.startswith(
            "MANIFEST-"
        ):
            raise ValueError("Invalid Arc cache manifest")
        manifest = (root / manifest_name).read_bytes()
        tables, log_number, previous_log = live_files(manifest)
        for number in tables:
            shutil.copyfile(root / f"{number:06d}.ldb", snapshot / f"{number:06d}.ldb")
        for path in root.glob("*.log"):
            if int(path.stem) >= log_number or int(path.stem) == previous_log:
                shutil.copyfile(path, snapshot / path.name)
        latest = {}

        def accept(key, sequence, data):
            if b"boost" not in key.lower():
                return
            if key not in latest or sequence >= latest[key][0]:
                latest[key] = (sequence, data)

        for path in snapshot.glob("*.ldb"):
            for internal_key, data in table(path.read_bytes()):
                tag = int.from_bytes(internal_key[-8:], "little")
                accept(internal_key[:-8], tag >> 8, data if tag & 255 == 1 else None)
        for path in snapshot.glob("*.log"):
            for record in records(path.read_bytes()):
                for key, sequence, data in batch_entries(record):
                    accept(key, sequence, data)
        result = {}
        for _, data in latest.values():
            if data is None:
                continue
            try:
                document = dict(proto(data))[2]
                fields = proto(document)
                name = dict(fields)[1].decode()
                if name.split("/")[-2] != "boosts":
                    continue
                decoded = {
                    proto(entry)[0][1].decode(): value(proto(entry)[1][1])
                    for number, entry in fields
                    if number == 2
                }
                if decoded:
                    result[name] = decoded
            except (ValueError, KeyError, IndexError, UnicodeDecodeError):
                continue
        return result


def css_rules(root):
    rules = []
    skipped = 0
    for identifier, fields in read_boosts(root).items():
        payload = json.loads(fields.get("data", "{}"))
        css = payload.get("css")
        if not isinstance(css, str) or not css.strip():
            continue
        pattern = fields.get("hostPattern")
        if not isinstance(pattern, str):
            skipped += 1
            continue
        rules.append(
            {
                "id": "arc:" + identifier.split("/")[-1],
                "name": fields.get("title") or "Arc CSS Boost",
                "pattern": pattern.lower(),
                "css": css,
                "enabled": fields.get("isActive") in (True, "true"),
            }
        )
    return rules, skipped
