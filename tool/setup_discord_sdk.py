#!/usr/bin/env python3
"""Install the Android/iOS 1.10.19337 SDK locally: setup_discord_sdk.py /path/to/sdk.zip."""
import argparse
import hashlib
from pathlib import Path
from zipfile import ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with ZipFile(args.archive) as archive:
        aar = archive.read("discord_social_sdk/lib/release/discord_partner_sdk.aar")
        if hashlib.sha256(aar).hexdigest() != "b1b2491f1e1848c79fd6f1986d5aa1e0c8019e88a6e62c7be06b89e8e4870933":
            parser.error("Expected the Android release SDK from DiscordSocialSdk-1.10.19337.zip")
        notices = archive.read("discord_social_sdk/License-Notices.txt")
        prefix = "discord_social_sdk/lib/release/discord_partner_sdk.xcframework/"
        ios_target = root / "ios/discord-sdk/discord_partner_sdk.xcframework"
        for entry in archive.infolist():
            if not entry.filename.startswith(prefix) or entry.is_dir():
                continue
            relative = Path(entry.filename[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts:
                parser.error("Invalid SDK archive path")
            destination = ios_target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(entry))
            if entry.external_attr >> 16 & 0o111:
                destination.chmod(0o755)
    target = root / "android/discord-sdk"
    target.mkdir(parents=True, exist_ok=True)
    (target / "discord_partner_sdk.aar").write_bytes(aar)
    (root / "assets/licenses/discord_social_sdk.txt").write_bytes(notices)
    print("Discord Android and iOS SDKs installed. Native SDK files remain ignored by Git.")


if __name__ == "__main__":
    main()
