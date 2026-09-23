#!/usr/bin/env python3
"""Merge one freshly generated appcast item into the published appcast.

generate_appcast rewrites the whole feed from whatever archives it is
pointed at, and stamps every item with the --download-url-prefix of that
run. Point it at a folder holding several releases and the old items come
back out with the newest tag's URL in their enclosure, which 404s for
anyone still on an older version. So release.sh runs it against a folder
containing only the new zip, and this script splices that single item into
docs/appcast.xml, leaving every previously published item exactly as it
was.

Usage:
  merge-appcast.py NEW_APPCAST PUBLISHED_APPCAST EXPECTED_VERSION [NOTES_MD]
"""

import html
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{ns}" xmlns:dc="{dc}">
  <channel>
    <title>MobaMac</title>
    <description>Updates for MobaMac</description>
    <language>en</language>
  </channel>
</rss>
""".format(ns=SPARKLE_NS, dc=DC_NS)


def short_version(item):
    """The item's marketing version, wherever this Sparkle version put it."""
    element = item.find(f"{{{SPARKLE_NS}}}shortVersionString")
    if element is not None and element.text:
        return element.text.strip()
    enclosure = item.find("enclosure")
    if enclosure is not None:
        value = enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString")
        if value:
            return value.strip()
    return None


def markdown_to_html(text):
    """Enough Markdown for a CHANGELOG section: paragraphs and one bullet list.

    Not a general converter on purpose. The release notes Sparkle shows come
    from one section of CHANGELOG.md, which is prose and "- " bullets and
    nothing else.
    """
    lines = [line.rstrip() for line in text.strip().splitlines()]
    parts = []
    bullets = []
    paragraph = []

    def flush_paragraph():
        if paragraph:
            parts.append("<p>" + html.escape(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def flush_bullets():
        if bullets:
            items = "".join(f"<li>{html.escape(b)}</li>" for b in bullets)
            parts.append(f"<ul>{items}</ul>")
            bullets.clear()

    for line in lines:
        if line.startswith("- "):
            flush_paragraph()
            bullets.append(line[2:].strip())
        elif not line.strip():
            flush_paragraph()
            flush_bullets()
        elif bullets:
            # A wrapped continuation of the bullet above it.
            bullets[-1] += " " + line.strip()
        else:
            paragraph.append(line.strip())

    flush_paragraph()
    flush_bullets()
    return "\n".join(parts)


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2

    new_path, published_path, expected_version = sys.argv[1:4]
    notes_path = sys.argv[4] if len(sys.argv) > 4 else None

    new_items = ET.parse(new_path).getroot().findall("./channel/item")
    if len(new_items) != 1:
        print(
            f"Expected exactly one item in {new_path}, found {len(new_items)}. "
            "The staging folder should hold only this release's zip.",
            file=sys.stderr,
        )
        return 1
    item = new_items[0]

    found_version = short_version(item)
    if found_version != expected_version:
        print(
            f"Appcast item says version {found_version!r} but this release is "
            f"{expected_version!r}. Sparkle compares versions literally, so "
            "publishing this would either hide the update or offer it forever.",
            file=sys.stderr,
        )
        return 1

    if notes_path:
        with open(notes_path, encoding="utf-8") as handle:
            notes = markdown_to_html(handle.read())
        if notes:
            for existing in item.findall("description"):
                item.remove(existing)
            description = ET.Element("description")
            description.text = notes
            item.insert(0, description)

    try:
        published = ET.parse(published_path).getroot()
    except (FileNotFoundError, ET.ParseError):
        published = ET.fromstring(EMPTY_FEED)

    channel = published.find("channel")
    if channel is None:
        print(f"{published_path} has no <channel>.", file=sys.stderr)
        return 1

    # Replacing a version rather than adding a duplicate, so re-running a
    # release is safe.
    for existing in channel.findall("item"):
        if short_version(existing) == expected_version:
            channel.remove(existing)

    first_item_index = len(list(channel))
    for index, child in enumerate(list(channel)):
        if child.tag == "item":
            first_item_index = index
            break
    channel.insert(first_item_index, item)

    ET.indent(published, space="  ")
    ET.ElementTree(published).write(
        published_path, encoding="utf-8", xml_declaration=True
    )
    print(f"Wrote {published_path} ({len(channel.findall('item'))} versions).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
