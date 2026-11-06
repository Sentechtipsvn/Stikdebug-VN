"""Check release identity and signing response before publishing CI artifacts."""
from pathlib import Path
import base64
import hashlib
import json
import plistlib
import sys

build = Path("build")
response = json.loads((build / "shortcut-signing-response.json").read_text())
assert response["success"] is True, "Shortcut signing service did not succeed"
metadata = response["file"]
source = Path("Shortcuts/StikDebug-VN.unsigned.shortcut").read_bytes()
signed = base64.b64decode(metadata["content_base64"], validate=True)
assert hashlib.sha256(source).hexdigest() == metadata["input_sha256"], "Signer used different input"
assert hashlib.sha256(signed).hexdigest() == metadata["signed_sha256"], "Signed download hash mismatch"
assert metadata["format"] == "AEA1" and metadata["signing_mode"] == "anyone"
assert signed[:4] == b"AEA1" and len(signed) == metadata["size"] and len(signed) > 1000
(build / "StikDebug-VN.shortcut").write_bytes(signed)
print("PASS: Shortcuts signing response, AEA1 envelope and input/output SHA-256 match")
if "--shortcut-only" in sys.argv: sys.exit(0)

app = build / "StikDebug-VN.xcarchive/Products/Applications/StikDebug.app"
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.sentechtipsvn.stikdebugvn", "Update would change app identity"
assert info["CFBundleShortVersionString"] == "3.2.2" and info["CFBundleVersion"] == "2"
assert info["CFBundleDisplayName"] == "StikDebug VN"
assert float(info["MinimumOSVersion"]) == 17.4
schemes = {scheme for item in info["CFBundleURLTypes"] for scheme in item["CFBundleURLSchemes"]}
assert schemes == {"stikdebugvn", "stikjitvn"}, "App URL schemes changed"
assert (app / info["CFBundleExecutable"]).stat().st_size > 1_000_000
assert not (app / "embedded.mobileprovision").exists(), "Unexpected personal provisioning profile"
print("PASS: 3.2.2 (2) keeps existing VN bundle ID, schemes, minimum OS and app name")
