"""Check release identity and signing response before publishing CI artifacts."""
from pathlib import Path
import hashlib
import json
import plistlib
import sys

build = Path("build")
metadata = json.loads(Path("Shortcuts/signing.json").read_text())
source = Path("Shortcuts/StikDebug-VN.unsigned.shortcut").read_bytes()
signed = Path("Shortcuts/StikDebug-VN.shortcut").read_bytes()
assert hashlib.sha256(source).hexdigest() == metadata["input_sha256"], "Signer used different input"
assert hashlib.sha256(signed).hexdigest() == metadata["signed_sha256"], "Signed download hash mismatch"
assert metadata["format"] == "AEA1" and metadata["signing_mode"] == "anyone"
assert signed[:4] == b"AEA1" and len(signed) == metadata["size"] and len(signed) > 1000
build.mkdir(exist_ok=True)
(build / "StikDebug-VN.shortcut").write_bytes(signed)
print("PASS: Shortcuts AEA1 envelope and signing-service input/output SHA-256 match")
if "--shortcut-only" in sys.argv: sys.exit(0)

app = build / "StikDebug-VN.xcarchive/Products/Applications/StikDebug.app"
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.sentechtipsvn.stikdebugvn", "Update would change app identity"
assert info["CFBundleShortVersionString"] == "3.2.6" and info["CFBundleVersion"] == "6"
assert info["CFBundleDisplayName"] == "StikDebug VN"
assert float(info["MinimumOSVersion"]) == 17.4
schemes = {scheme for item in info["CFBundleURLTypes"] for scheme in item["CFBundleURLSchemes"]}
assert schemes == {"stikdebugvn", "stikjitvn"}, "App URL schemes changed"
assert (app / info["CFBundleExecutable"]).stat().st_size > 1_000_000
assert not (app / "embedded.mobileprovision").exists(), "Unexpected personal provisioning profile"
print("PASS: 3.2.6 (6) keeps existing VN bundle ID, schemes, minimum OS and app name")
