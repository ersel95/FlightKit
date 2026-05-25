#!/usr/bin/env python3
"""Insert or update one release <item> in appcast.xml (Sparkle's update feed).

The CI release job signs the DMG with Sparkle's `sign_update` (EdDSA), then calls
this to add the new version to the feed that the app polls via `SUFeedURL`. Re-runs
for the same version replace the existing item, so the script is idempotent.

Usage:
  update_appcast.py --version 1.0.3 \
    --url https://github.com/ersel95/FlightKit/releases/download/v1.0.3/FlightKit-1.0.3.dmg \
    --length 4192836 --signature 'BASE64==' [--notes-url URL] [--min-system 14.0] \
    [--appcast appcast.xml]
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sk(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def load_or_create(path: str):
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        if root.find("channel") is None:
            ET.SubElement(root, "channel")
        return tree, root
    except (FileNotFoundError, ET.ParseError):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "FlightKit"
        ET.SubElement(channel, "link").text = "https://github.com/ersel95/FlightKit"
        ET.SubElement(channel, "description").text = "FlightKit updates"
        return ET.ElementTree(root), root


def build_item(args) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"FlightKit {args.version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, sk("version")).text = args.version
    ET.SubElement(item, sk("shortVersionString")).text = args.version
    ET.SubElement(item, sk("minimumSystemVersion")).text = args.min_system
    if args.notes_url:
        ET.SubElement(item, sk("releaseNotesLink")).text = args.notes_url
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", str(args.length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sk("edSignature"), args.signature)
    return item


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes-url", default="")
    p.add_argument("--min-system", default="14.0")
    p.add_argument("--appcast", default="appcast.xml")
    args = p.parse_args()

    tree, root = load_or_create(args.appcast)
    channel = root.find("channel")

    # Drop any existing item for this version so re-runs stay idempotent.
    for it in channel.findall("item"):
        if it.findtext(sk("version")) == args.version:
            channel.remove(it)

    item = build_item(args)
    first_item = channel.find("item")
    if first_item is not None:
        channel.insert(list(channel).index(first_item), item)  # newest first
    else:
        channel.append(item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast.xml updated for {args.version}")


if __name__ == "__main__":
    main()
