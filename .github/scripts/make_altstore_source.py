"""Generate an AltStore Classic feed from an unsigned StikDebug VN CI artifact."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
from zipfile import BadZipFile, ZipFile

APP_ID = "com.sentechtipsvn.stikdebugvn"
VERSION = r"[0-9]+(?:\.[0-9]+){0,2}"
TAG = re.compile(rf"vn-v({VERSION})-build({VERSION})")


def version_key(version, build):
    parts = [tuple(map(int, value.split("."))) for value in (version, build)]
    return tuple(part + (0,) * (3 - len(part)) for part in parts)


def verify_unsigned(archive, executable):
    with archive.open(executable) as stream:
        header = stream.read(32)
        if len(header) != 32 or header[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError(f"Expected a thin 64-bit Mach-O: {executable}")
        count, size = struct.unpack_from("<II", header, 16)
        if size > 1024 * 1024:
            raise ValueError(f"Invalid Mach-O load commands: {executable}")
        commands = stream.read(size)
    position = 0
    for _ in range(count):
        command, length = struct.unpack_from("<II", commands, position)
        if length < 8 or position + length > len(commands):
            raise ValueError(f"Invalid Mach-O load command: {executable}")
        if command == 0x1D or (
            command == 0x19 and b"__entitlements" in commands[position:position + length]
        ):
            raise ValueError("This publisher requires unsigned CI packages without embedded entitlements.")
        position += length
    if position != size or len(commands) != size:
        raise ValueError(f"Incomplete Mach-O load commands: {executable}")


def read_app(ipa):
    with ZipFile(ipa) as archive:
        names = archive.namelist()
        apps = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(apps) != 1 or any(name.endswith("/embedded.mobileprovision") for name in names):
            raise ValueError("Expected one unsigned app without provisioning profiles.")
        app_info_path = apps[0]
        app = plistlib.loads(archive.read(app_info_path))
        if app["CFBundleIdentifier"] != APP_ID:
            raise ValueError(f"Expected StikDebug VN bundle ID {APP_ID}.")
        root = PurePosixPath(app_info_path).parent
        extensions = [
            name for name in names
            if name.startswith(f"{root}/PlugIns/") and name.endswith(".appex/Info.plist")
        ]
        privacy = {}
        for info_path in [app_info_path, *extensions]:
            info = plistlib.loads(archive.read(info_path))
            executable = info["CFBundleExecutable"]
            if not executable or PurePosixPath(executable).name != executable:
                raise ValueError("Invalid application executable name.")
            verify_unsigned(archive, str(PurePosixPath(info_path).parent / executable))
            for key, description in info.items():
                if re.fullmatch(r"NS.*UsageDescription", key):
                    if not isinstance(description, str):
                        raise ValueError(f"Invalid privacy description for {key}.")
                    privacy.setdefault(key, description)
    return app, privacy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--releases", type=Path)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args()

    try:
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repository, re.ASCII):
            raise ValueError("Expected GitHub repository owner/name.")
        if not re.fullmatch("[0-9a-f]{40}", args.commit):
            raise ValueError("Expected a full lowercase Git commit SHA.")
        if not re.fullmatch(r"StikDebug-VN-[0-9.]+-[0-9a-f]{7}\.ipa", args.ipa.name):
            raise ValueError("Expected a VN build artifact filename.")
        if not args.ipa.name.endswith(f"-{args.commit[:7]}.ipa"):
            raise ValueError("IPA filename does not match the chosen build commit.")
        app, privacy = read_app(args.ipa)
        version, build, minimum = (app[key] for key in (
            "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion",
        ))
        if any(not isinstance(value, str) or not re.fullmatch(VERSION, value)
               for value in (version, build, minimum)):
            raise ValueError("Invalid version, build or minimum OS in Info.plist.")
        tag = f"vn-v{version}-build{build}"
        current_key = version_key(version, build)

        if args.releases:
            for release in json.loads(args.releases.read_text(encoding="utf-8")):
                old = TAG.fullmatch(release["tag_name"])
                if not release["draft"] and not release["prerelease"] and old:
                    if version_key(*old.groups()) >= current_key:
                        raise ValueError(f"{old[0]} is already published. Choose a newer build.")

        versions = []
        if args.previous:
            previous = json.loads(args.previous.read_text(encoding="utf-8"))
            previous_apps = previous["apps"]
            if len(previous_apps) != 1 or previous_apps[0]["bundleIdentifier"] != APP_ID:
                raise ValueError("Previous feed belongs to a different app.")
            old_app = previous_apps[0]
            if old_app["appPermissions"]["entitlements"]:
                raise ValueError("Previous feed uses a different signing model.")
            privacy = {**old_app["appPermissions"]["privacy"], **privacy}
            versions = old_app["versions"]
            for entry in versions:
                if version_key(entry["version"], entry["buildVersion"]) >= current_key:
                    raise ValueError("Previous feed already includes this or a newer version.")

        website = f"https://github.com/{args.repository}"
        icon = f"https://raw.githubusercontent.com/{args.repository}/{args.commit}/assets/StikDebug.png"
        with args.ipa.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        versions.insert(0, {
            "version": version,
            "buildVersion": build,
            "date": datetime.now(timezone.utc).date().isoformat(),
            "downloadURL": f"{website}/releases/download/{tag}/{args.ipa.name}",
            "size": args.ipa.stat().st_size,
            "sha256": digest,
            "minOSVersion": minimum,
        })
        source = {
            "name": "StikDebug VN",
            "subtitle": "Nguồn cập nhật StikDebug VN cho AltStore Classic",
            "website": website,
            "iconURL": icon,
            "tintColor": "34C759",
            "featuredApps": [APP_ID],
            "apps": [{
                "name": "StikDebug VN",
                "bundleIdentifier": APP_ID,
                "developerName": "StikDebug · SenTechTipsVN",
                "localizedDescription": (
                    "Bản tiếng Việt do SenTechTipsVN tuỳ biến từ dự án StikDebug. "
                    "Hỗ trợ JIT, công cụ gỡ lỗi và mô phỏng vị trí, tuyến đường."
                ),
                "iconURL": icon,
                "tintColor": "34C759",
                "versions": versions,
                "appPermissions": {"entitlements": [], "privacy": privacy},
            }],
            "news": [],
        }
        args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(tag)
    except (OSError, ValueError, KeyError, TypeError, struct.error, BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Cannot generate AltStore source: {error}\n")


if __name__ == "__main__":
    main()
