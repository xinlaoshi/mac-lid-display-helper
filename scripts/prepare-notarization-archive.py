#!/usr/bin/env python3
"""Prepare a local archive for Xcode's Developer ID distribution workflow."""
import argparse
import datetime
from pathlib import Path
import plistlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-id", required=True, help="Active Xcode developer team ID")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("team ID must contain 10 uppercase letters or digits")

    root = Path(__file__).resolve().parents[1]
    source = root / "output/Mac合盖和显示器联动助手.app"
    if not (source / "Contents/Info.plist").is_file():
        parser.error("build the app with bash scripts/build.sh first")
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleExecutable") != "MacDisplaySwitch" or not (source / "Contents/MacOS/MacDisplaySwitch").is_file():
        parser.error("rebuild the app with its MacDisplaySwitch executable first")
    name = f"MacDisplaySwitch-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}"
    directory = root / "output/notarization"
    archive = directory / f"{name}.xcarchive"
    if archive.exists():
        parser.error(f"archive already exists; preserve its submission history: {archive}")
    app = archive / "Products/Applications" / source.name
    subprocess.run(["ditto", str(source), str(app)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime",
                    "--timestamp=none", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    metadata = {
        "ArchiveVersion": 2,
        "CreationDate": datetime.datetime.now(datetime.timezone.utc),
        "Name": "Mac合盖和显示器联动助手",
        "SchemeName": "MacDisplaySwitch",
        "ApplicationProperties": {
            "ApplicationPath": "Applications/" + source.name,
            "CFBundleIdentifier": info["CFBundleIdentifier"],
            "CFBundleShortVersionString": info["CFBundleShortVersionString"],
            "CFBundleVersion": info["CFBundleVersion"],
            "SigningIdentity": "-", "Team": args.team_id, "Architectures": ["arm64"],
        },
    }
    (archive / "Info.plist").write_bytes(plistlib.dumps(metadata))
    options = directory / f"{name}-ExportOptions.plist"
    options.write_bytes(plistlib.dumps({
        "method": "developer-id", "destination": "upload", "signingStyle": "automatic",
        "teamID": args.team_id, "signingCertificate": "Developer ID Application",
        "stripSwiftSymbols": False,
    }))
    print(f"Archive: {archive}\nExport options: {options}")
    print("Local preparation only. Use Xcode export to sign with Developer ID and submit to Apple.")


if __name__ == "__main__":
    main()
