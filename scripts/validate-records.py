#!/usr/bin/env python3
"""Checks records written by the tests against Bluesky's official lexicon files.

Usage: validate-records.py <folder with lexicon .json files> <records.json>

A deliberately small validator: required fields, types, unions, references and the string
formats and limits the app's records use. It needs only the Python standard library.
"""
import json
import os
import re
import sys
import unicodedata


def load(folder):
    lexicons = {}
    for name in os.listdir(folder):
        if name.endswith(".json"):
            with open(os.path.join(folder, name)) as handle:
                document = json.load(handle)
            lexicons[document["id"]] = document
    return lexicons


FORMATS = {
    "at-uri": re.compile(r"^at://[A-Za-z0-9:._-]+(/[a-zA-Z0-9.-]+(/[A-Za-z0-9._~:-]+)?)?$"),
    "did": re.compile(r"^did:[a-z]+:[A-Za-z0-9._:%-]+$"),
    "cid": re.compile(r"^(baf[a-z2-7]{20,}|Qm[1-9A-HJ-NP-Za-km-z]{44})$"),
    "datetime": re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"),
    "uri": re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:\S+$"),
    "language": re.compile(r"^[a-zA-Z]{2,3}(-[A-Za-z0-9-]+)?$"),
}


def graphemes(text):
    # Close enough for limits: combining marks do not count as characters of their own.
    return sum(1 for char in text if not unicodedata.combining(char))


class Validator:
    def __init__(self, lexicons):
        self.lexicons = lexicons

    def resolve(self, ref, current):
        nsid, _, name = ref.partition("#")
        nsid = nsid or current
        document = self.lexicons.get(nsid)
        if document is None:
            raise LookupError(f"lexicon missing: {nsid}")
        return document["defs"][name or "main"], nsid

    def check(self, schema, value, nsid, path, errors):
        kind = schema.get("type")
        if kind == "ref":
            target, target_nsid = self.resolve(schema["ref"], nsid)
            self.check(target, value, target_nsid, path, errors)
        elif kind == "union":
            self.check_union(schema, value, nsid, path, errors)
        elif kind in ("object", "record"):
            self.check_object(schema.get("record", schema), value, nsid, path, errors)
        elif kind == "array":
            self.check_array(schema, value, nsid, path, errors)
        elif kind == "string":
            self.check_string(schema, value, path, errors)
        elif kind == "integer":
            if not isinstance(value, int) or isinstance(value, bool):
                errors.append(f"{path}: not an integer")
            elif "minimum" in schema and value < schema["minimum"]:
                errors.append(f"{path}: below minimum")
        elif kind == "boolean":
            if not isinstance(value, bool):
                errors.append(f"{path}: not a boolean")
        elif kind == "blob":
            self.check_blob(schema, value, path, errors)
        elif kind == "unknown":
            if not isinstance(value, dict):
                errors.append(f"{path}: not an object")

    def check_object(self, schema, value, nsid, path, errors):
        if not isinstance(value, dict):
            errors.append(f"{path}: not an object")
            return
        for name in schema.get("required", []):
            if name not in value:
                errors.append(f"{path}.{name}: required but missing")
        for name, field in schema.get("properties", {}).items():
            if name in value:
                self.check(field, value[name], nsid, f"{path}.{name}", errors)

    def check_array(self, schema, value, nsid, path, errors):
        if not isinstance(value, list):
            errors.append(f"{path}: not an array")
            return
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: too many items")
        for index, item in enumerate(value):
            self.check(schema["items"], item, nsid, f"{path}[{index}]", errors)

    def check_string(self, schema, value, path, errors):
        if not isinstance(value, str):
            errors.append(f"{path}: not a string")
            return
        if "maxGraphemes" in schema and graphemes(value) > schema["maxGraphemes"]:
            errors.append(f"{path}: too long")
        if "maxLength" in schema and len(value.encode()) > schema["maxLength"]:
            errors.append(f"{path}: too many bytes")
        pattern = FORMATS.get(schema.get("format"))
        if pattern and not pattern.match(value):
            errors.append(f"{path}: not a valid {schema['format']}: {value}")

    def check_union(self, schema, value, nsid, path, errors):
        if not isinstance(value, dict) or "$type" not in value:
            errors.append(f"{path}: union member without $type")
            return
        wanted = value["$type"]
        for ref in schema["refs"]:
            full = ref if not ref.startswith("#") else nsid + ref
            if full == wanted or full == wanted + "#main":
                target, target_nsid = self.resolve(ref, nsid)
                self.check(target, value, target_nsid, path, errors)
                return
        if schema.get("closed"):
            errors.append(f"{path}: {wanted} is not allowed here")
        else:
            known = [ref for ref in schema["refs"]]
            errors.append(f"{path}: {wanted} is not one of the known types {known}")

    def check_blob(self, schema, value, path, errors):
        if not isinstance(value, dict) or value.get("$type") != "blob":
            errors.append(f"{path}: not a blob")
            return
        link = value.get("ref", {}).get("$link", "")
        if not FORMATS["cid"].match(link):
            errors.append(f"{path}.ref: not a valid cid: {link}")
        if not isinstance(value.get("size"), int):
            errors.append(f"{path}.size: not an integer")
        accepted = schema.get("accept")
        mime = value.get("mimeType", "")
        if accepted and not any(a == mime or (a.endswith("/*") and mime.startswith(a[:-1])) for a in accepted):
            errors.append(f"{path}.mimeType: {mime} not accepted")

    def validate(self, collection, record):
        errors = []
        if record.get("$type") != collection:
            errors.append(f"$type is {record.get('$type')}, expected {collection}")
        main, nsid = self.resolve(collection, collection)
        self.check(main, record, nsid, "record", errors)
        return errors


def main():
    validator = Validator(load(sys.argv[1]))
    with open(sys.argv[2]) as handle:
        items = json.load(handle)
    invalid = 0
    counts = {}
    for item in items:
        collection, record = item["collection"], item["record"]
        counts[collection] = counts.get(collection, 0) + 1
        errors = validator.validate(collection, record)
        if errors:
            invalid += 1
            print("INVALID", collection, errors, json.dumps(record)[:220])
    print(f"checked {len(items)} records, invalid {invalid}: {counts}")

    # The validator has to be able to fail, or a clean result proves nothing.
    cid = "bafkreihybpskotkosezr4yzvkj5et62qpf32efvz4wulirfieqii7p2axy"
    now = "2026-01-01T00:00:00.000Z"
    controls = [
        ("no text", "app.bsky.feed.post", {"$type": "app.bsky.feed.post", "createdAt": now}),
        ("301 characters", "app.bsky.feed.post", {"$type": "app.bsky.feed.post", "text": "x" * 301, "createdAt": now}),
        ("bad date", "app.bsky.feed.like", {"$type": "app.bsky.feed.like", "subject": {"uri": "at://did:plc:a/app.bsky.feed.post/3a", "cid": cid}, "createdAt": "gestern"}),
        ("bad cid", "app.bsky.feed.like", {"$type": "app.bsky.feed.like", "subject": {"uri": "at://did:plc:a/app.bsky.feed.post/3a", "cid": "cnew"}, "createdAt": now}),
        ("no subject", "app.bsky.graph.block", {"$type": "app.bsky.graph.block", "createdAt": now}),
        ("wrong embed", "app.bsky.feed.post", {"$type": "app.bsky.feed.post", "text": "x", "createdAt": now, "embed": {"$type": "app.bsky.embed.images#view", "images": []}}),
        ("wrong facet range", "app.bsky.feed.post", {"$type": "app.bsky.feed.post", "text": "x", "createdAt": now, "facets": [{"index": {"byteStart": -1, "byteEnd": 1}, "features": [{"$type": "app.bsky.richtext.facet#tag", "tag": "x"}]}]}),
        ("wrong rule", "app.bsky.feed.threadgate", {"$type": "app.bsky.feed.threadgate", "post": "at://did:plc:a/app.bsky.feed.post/3a", "createdAt": now, "allow": [{"$type": "app.bsky.feed.threadgate#nope"}]}),
    ]
    missed = 0
    for name, collection, record in controls:
        if validator.validate(collection, record):
            print("control caught:", name)
        else:
            missed += 1
            print("CONTROL NOT CAUGHT:", name)
    sys.exit(1 if invalid or missed else 0)


if __name__ == "__main__":
    main()
