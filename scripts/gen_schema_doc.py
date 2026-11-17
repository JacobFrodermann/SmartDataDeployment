#!/usr/bin/env python3
"""Generate the schema-table sections of docs/schemas.md from the preset JSONs.

Usage: python3 scripts/gen_schema_doc.py > /tmp/schema_tables.md
Read-only: never writes to the submodules.
"""
import json
import os
import glob
import collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return json.load(fh)


def attr_row(a):
    name = a.get("name", "?")
    typ = a.get("type", "")
    flags = []
    if a.get("isIdentity"):
        flags.append("identity")
    if a.get("isAutoIncrement"):
        flags.append("auto-increment")
    if a.get("isNullable") is False:
        flags.append("NOT NULL")
    if a.get("default"):
        flags.append(f"default `{a['default']}`")
    if a.get("defaultvalue"):
        flags.append(f"default `{a['defaultvalue']}`")
    ref = ""
    if a.get("refCollection"):
        ref = f" -> `{a['refCollection']}.{a.get('refAttribute', 'id')}`"
        if a.get("refOnDelete") or a.get("refOnUpdate"):
            acts = "/".join(x for x in (a.get("refOnDelete"), a.get("refOnUpdate")) if x)
            ref += f" ({acts})"
    return f"| `{name}` | {typ} | {', '.join(flags) or ' '} |{ref}"


def emit_collection(title, coll, note=None):
    print(f"#### `{coll['name']}`" + (f" — {note}" if note else ""))
    print()
    print("| Attribute | Type | Constraints | Reference |")
    print("| --- | --- | --- | --- |")
    attrs = coll.get("attributes") or coll.get("body", {}).get("attributes", [])
    for a in attrs:
        print(attr_row(a))
    print()


# ---------- SmartMonitoringFrontend base.json ----------
print("<!-- SMF base -->")
d = load("SmartMonitoringFrontend/data/admin/presets/base.json")
for item in d["list"]:
    print(f"### {item['name']} (v{item['version']})")
    print()
    print(f"Preset: `SmartMonitoringFrontend/data/admin/presets/base.json` — "
          f"{item['desc']}. Checks state of: {', '.join('`' + s['name'] + '`' for s in item.get('state', []))}.")
    print()
    for c in item.get("collections", []):
        emit_collection("", c["body"] if "body" in c else c)

# ---------- SmartDataJobs base.json ----------
print("<!-- SDJ base -->")
d = load("SmartDataJobs/web/data/admin/presets/base.json")
for item in d["list"]:
    print(f"### {item['name']} (v{item['version']})")
    print()
    for c in item.get("collections", []):
        emit_collection("", c["body"])

# ---------- functions.json ----------
print("<!-- functions -->")
d = load("SmartMonitoringFrontend/data/admin/functions/functions.json")
for item in d["list"]:
    for c in item.get("collections", []):
        emit_collection("", c, note=f"owned by `{item['name']}` (id {item['id']})")

# ---------- legacy ----------
print("<!-- legacy -->")
files = sorted(glob.glob(os.path.join(ROOT, "SmartMonitoringFrontend/data/admin/presets/legacy/*/*_attributes.json")))
tables = {}
for f in files:
    with open(f, encoding="utf-8") as fh:
        d = json.load(fh)
    tname = os.path.basename(f)[len("tbl_"):-len("_attributes.json")] if False else os.path.basename(f)[:-len("_attributes.json")]
    preset = os.path.basename(os.path.dirname(f))
    if tname not in tables:
        tables[tname] = {"attrs": d.get("attributes", []), "presets": set()}
    tables[tname]["presets"].add(preset)
for tname, t in sorted(tables.items()):
    print(f"#### `{tname}` — legacy, in {len(t['presets'])} preset folder(s)")
    print()
    print("| Attribute | Type | Constraints | Reference |")
    print("| --- | --- | --- | --- |")
    for a in t["attrs"]:
        print(attr_row(a))
    print()
