#!/usr/bin/env python3
"""Reject an app that verifies cryptographically but cannot access shared credentials.

Run on macOS before installing a normal app build. Unsigned/ad-hoc, memory-only
QA copies are not installable user builds. This checks bundle identity, signed
Keychain/iCloud entitlements, and the matching embedded development profile;
it never reads or changes Keychain items.
"""

import datetime
import hashlib
import pathlib
import plistlib
import subprocess
import sys
import tempfile


def run(*arguments: str) -> bytes:
    result = subprocess.run(arguments, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", "replace").strip())
    return result.stdout


def verify(app: pathlib.Path) -> None:
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signed = run("codesign", "-d", "--entitlements", "-", str(app))
    if not signed.strip():
        raise ValueError("No signed entitlements; this is not a credential-capable app build.")
    entitlements = plistlib.loads(signed)
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    team = entitlements.get("com.apple.developer.team-identifier")
    if not isinstance(team, str) or not team:
        raise ValueError("Missing signed development-team identity.")
    bundle_id = info["CFBundleIdentifier"]
    application_id = f"{team}.{bundle_id}"
    if entitlements.get("com.apple.application-identifier") != application_id:
        raise ValueError("Signed application identity does not match the bundle and team.")
    group = info.get("MailternalKeychainAccessGroup")
    if group != application_id or group not in entitlements.get("keychain-access-groups", []):
        raise ValueError("Info.plist and signed shared-Keychain access group do not agree.")
    if "CloudKit" not in entitlements.get("com.apple.developer.icloud-services", []):
        raise ValueError("Missing signed CloudKit capability.")
    profile_path = app / "Contents/embedded.provisionprofile"
    if not profile_path.is_file():
        raise ValueError("Missing embedded provisioning profile for restricted capabilities.")
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(profile_path)))
    if team not in profile.get("TeamIdentifier", []):
        raise ValueError("Provisioning profile belongs to another development team.")
    if profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("Provisioning profile has expired.")
    granted = profile["Entitlements"]
    if granted.get("com.apple.application-identifier") not in (application_id, f"{team}.*"):
        raise ValueError("Provisioning profile does not authorize this application.")
    if not any(group == value or value == f"{team}.*" for value in granted.get("keychain-access-groups", [])):
        raise ValueError("Provisioning profile does not authorize the shared Keychain group.")
    with tempfile.TemporaryDirectory(prefix="mailternal-signing-check-") as temporary:
        prefix = pathlib.Path(temporary) / "certificate"
        run("codesign", "-d", "--extract-certificates", str(prefix), str(app))
        leaf_path = pathlib.Path(str(prefix) + "0")
        run("security", "verify-cert", "-p", "codeSign", "-c", str(leaf_path))
        leaf = leaf_path.read_bytes()
        allowed = {hashlib.sha256(value).digest() for value in profile.get("DeveloperCertificates", [])}
        if hashlib.sha256(leaf).digest() not in allowed:
            raise ValueError("Signing certificate is not authorized by the embedded profile.")
    print(f"PASS credential-capable signature: {bundle_id}, team {team}, shared Keychain group matches")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: verify-app-signing.py Mailternal.app")
    try:
        verify(pathlib.Path(sys.argv[1]))
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        sys.exit(f"FAIL app signing: {error}")
