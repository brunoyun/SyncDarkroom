#!/usr/bin/env python3
"""Adds a release to the AltStore source (altstore/source.json).

Run by the release workflow after the IPA is uploaded to the GitHub release; it can
also be run by hand. Repository-specific URLs are derived from --repo, so nothing
personal is hardcoded.

Example:
  scripts/update_source.py --version 0.2.0 --build 7 --ipa build/SyncDarkroom.ipa \
      --repo someone/SyncDarkroom --branch main --notes-file build/notes.md
"""
import argparse
import datetime
import json
import os
import sys

SOURCE_PATH = os.path.join(os.path.dirname(__file__), "..", "altstore", "source.json")
BUNDLE_ID = "com.syncdarkroom.app"
TINT = "#FF9933"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", required=True, help="marketing version, e.g. 0.2.0")
    p.add_argument("--build", required=True, help="build number (CFBundleVersion)")
    p.add_argument("--ipa", required=True, help="path to the built .ipa (for its size)")
    p.add_argument("--repo", required=True, help="GitHub owner/name")
    p.add_argument("--branch", default="main", help="branch that hosts altstore/ (default: main)")
    p.add_argument("--notes-file", help="release notes (plain text/markdown)")
    p.add_argument("--min-os", default="17.0")
    p.add_argument("--source", default=SOURCE_PATH)
    args = p.parse_args()

    owner, _, name = args.repo.partition("/")
    if not owner or not name:
        print("--repo must look like owner/name", file=sys.stderr)
        return 1

    raw_base = f"https://raw.githubusercontent.com/{args.repo}/{args.branch}/altstore"
    notes = f"SyncDarkroom {args.version}"
    if args.notes_file and os.path.exists(args.notes_file):
        text = open(args.notes_file, encoding="utf-8").read().strip()
        if text:
            notes = text

    try:
        source = json.load(open(args.source, encoding="utf-8"))
    except FileNotFoundError:
        source = {}

    source.update({
        "name": "SyncDarkroom",
        "identifier": f"io.github.{owner.lower()}.syncdarkroom",
        "subtitle": "Edit photos right in your synced folder.",
        "description": "SyncDarkroom is an iPad photo editor that works directly on a folder kept in sync "
                       "(for example with Synctrain/Syncthing). Edits are saved as copies next to the "
                       "originals, with adjustable settings that sync too.",
        "iconURL": f"{raw_base}/icon.png",
        "website": f"https://github.com/{args.repo}",
        "tintColor": TINT,
    })
    source.setdefault("news", [])

    apps = source.setdefault("apps", [])
    app = next((a for a in apps if a.get("bundleIdentifier") == BUNDLE_ID), None)
    if app is None:
        app = {"bundleIdentifier": BUNDLE_ID, "versions": []}
        apps.insert(0, app)
    app.update({
        "name": "SyncDarkroom",
        "developerName": owner,
        "subtitle": "Photo editor for synced folders",
        "localizedDescription": "Browse a Synctrain/Syncthing folder and edit photos non-destructively: "
                                "light, color, curves, HSL, presets, RAW develop, crop and perspective, "
                                "masks, healing, Apple Pencil markup and batch edits. Originals are never "
                                "modified — every edit is a new copy, and its settings sync with the folder.",
        "iconURL": f"{raw_base}/icon.png",
        "tintColor": TINT,
        "category": "photo-video",
        "screenshots": app.get("screenshots", []),
        "appPermissions": {"entitlements": [], "privacy": {}},
    })

    version = {
        "version": args.version,
        "buildVersion": str(args.build),
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": notes,
        "downloadURL": f"https://github.com/{args.repo}/releases/download/v{args.version}/SyncDarkroom.ipa",
        "size": os.path.getsize(args.ipa),
        "minOSVersion": args.min_os,
    }
    versions = [v for v in app.get("versions", []) if v.get("version") != args.version]
    app["versions"] = [version] + versions

    os.makedirs(os.path.dirname(os.path.abspath(args.source)), exist_ok=True)
    with open(args.source, "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"Added {args.version} ({args.build}) to {args.source}; {len(app['versions'])} version(s) listed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
