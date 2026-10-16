#!/usr/bin/env python3
"""Print the metainfo with a <release> entry for VERSION, adding one if missing.

usage: metainfo.py METAINFO VERSION [NOTES_MARKDOWN]

The description comes from the "What's new" section of the GitHub release
notes; without notes the entry has no description.
"""
import datetime
import re
import sys
from xml.sax.saxutils import escape


def paragraphs(notes_path):
    text = open(notes_path, encoding="utf-8").read()
    m = re.search(r"^## What's new\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    body = m.group(1) if m else ""
    return [" ".join(p.split()) for p in re.split(r"\n\s*\n", body) if p.strip()]


def main():
    path, version = sys.argv[1], sys.argv[2]
    notes = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
    xml = open(path, encoding="utf-8").read()
    if f'<release version="{version}"' in xml:
        sys.stdout.write(xml)
        return
    today = datetime.date.today().isoformat()
    paras = paragraphs(notes) if notes else []
    desc = ""
    if paras:
        desc = "\n      <description>\n" + "".join(
            f"        <p>{escape(p)}</p>\n" for p in paras) + "      </description>\n    "
    entry = f'<release version="{version}" date="{today}">{desc}</release>\n    '
    if "<releases>" not in xml:
        sys.exit("metainfo has no <releases> element")
    sys.stdout.write(xml.replace("<releases>\n    ", "<releases>\n    " + entry, 1))


if __name__ == "__main__":
    main()
