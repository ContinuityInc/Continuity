#!/usr/bin/env python3
"""Install the Apple Distribution cert and App Store profiles TestFlight archive needs.

Xcode 26 rejects Automatic signing combined with an Apple Distribution identity, and
plain Automatic signing mints a new Apple Development certificate on every ephemeral
runner until the account hits Apple's cap. Manual signing avoids both, but only if a
profile that actually contains the app group is already installed — Xcode will not
create one for a manually signed target.

This script uses the existing App Store Connect API key to reuse or create one
Distribution certificate, install App Store profiles for the app and the share
extension (regenerating them until they include the app group), and write the
Release xcconfigs xcodegen reads. Nothing here is committed; the .p12 stays in the
Actions cache.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_ROOT = "https://api.appstoreconnect.apple.com"
APP_GROUP = "group.com.sanylax.continuity"
TEAM_ID = "KP832RV67A"
# Names are also the PROVISIONING_PROFILE_SPECIFIER values. No spaces: xcconfig
# treats an unquoted space as a delimiter.
TARGETS = (
    ("com.sanylax.continuity", "ContinuityCIStore", "Signing/Continuity.release.xcconfig"),
    (
        "com.sanylax.continuity.share",
        "ContinuityShareCIStore",
        "Signing/ContinuityShare.release.xcconfig",
    ),
)
ROOT = Path(__file__).resolve().parents[2]


class APIError(Exception):
    def __init__(self, method: str, path: str, status: int, body: str):
        super().__init__(f"App Store Connect {method} {path} failed: HTTP {status} {body}")
        self.status = status
        self.body = body


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_length(data: bytes, index: int) -> tuple[int, int]:
    first = data[index]
    index += 1
    if first & 0x80:
        count = first & 0x7F
        length = int.from_bytes(data[index : index + count], "big")
        return length, index + count
    return first, index


def der_ecdsa_to_raw(der: bytes) -> bytes:
    """Convert an OpenSSL DER ECDSA signature to the raw R||S form JWT ES256 needs."""
    if not der or der[0] != 0x30:
        raise ValueError("ECDSA signature is not a DER sequence")
    _, index = _der_length(der, 1)

    def read_int(pos: int) -> tuple[bytes, int]:
        if der[pos] != 0x02:
            raise ValueError("ECDSA signature is missing an integer")
        length, start = _der_length(der, pos + 1)
        return der[start : start + length], start + length

    r, index = read_int(index)
    s, _ = read_int(index)

    def fixed(component: bytes) -> bytes:
        component = component.lstrip(b"\x00")
        if len(component) > 32:
            raise ValueError("ECDSA component is longer than 32 bytes")
        return component.rjust(32, b"\x00")

    return fixed(r) + fixed(s)


def sign_es256(key_path: Path, message: bytes) -> bytes:
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=message,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", "replace"))
    return der_ecdsa_to_raw(result.stdout)


def make_token(key_id: str, issuer_id: str, key_path: Path, now: int | None = None) -> str:
    issued = int(time.time()) if now is None else now
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(
        json.dumps(
            {"iss": issuer_id, "iat": issued, "exp": issued + 15 * 60, "aud": "appstoreconnect-v1"},
            separators=(",", ":"),
        ).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    return f"{header}.{payload}.{b64url(sign_es256(key_path, signing_input))}"


def api(token: str, method: str, path: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(API_ROOT + path, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise APIError(method, path, error.code, detail) from error
    if not raw:
        return {}
    return json.loads(raw)


def list_all(token: str, path: str) -> list[dict]:
    items: list[dict] = []
    while path:
        page = api(token, "GET", path)
        items.extend(page.get("data", []))
        nxt = page.get("links", {}).get("next")
        if not nxt:
            break
        marker = "api.appstoreconnect.apple.com"
        path = nxt.split(marker, 1)[1] if marker in nxt else None
    return items


def normalize_serial(serial: str) -> str:
    return serial.replace(":", "").replace(" ", "").lower().lstrip("0")


def openssl_supports_legacy() -> bool:
    result = subprocess.run(["openssl", "pkcs12", "-help"], capture_output=True, text=True)
    return "-legacy" in result.stdout or "-legacy" in result.stderr


def p12_certificate_der(p12: Path, password: str) -> bytes:
    command = [
        "openssl",
        "pkcs12",
        "-in",
        str(p12),
        "-nokeys",
        "-passin",
        f"pass:{password}",
    ]
    if openssl_supports_legacy():
        command.append("-legacy")
    pem = run(command, secret=True)
    der = run(["openssl", "x509", "-outform", "DER"], input=pem.stdout)
    return der.stdout


def certificate_serial(der: bytes) -> str:
    result = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-serial"],
        input=der,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", "replace"))
    return normalize_serial(result.stdout.decode().split("=", 1)[-1])


def p12_password(api_key: bytes) -> str:
    # Stable for this API key, so a restored cache can be unlocked without another secret.
    return hashlib.sha256(b"continuity-distribution-v1\n" + api_key).hexdigest()


def matching_certificate_id(token: str, der: bytes) -> str | None:
    serial = certificate_serial(der)
    certificates = list_all(token, "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50")
    for certificate in certificates:
        attributes = certificate.get("attributes") or {}
        if normalize_serial(str(attributes.get("serialNumber", ""))) == serial:
            return certificate["id"]
        content = attributes.get("certificateContent")
        if content and base64.b64decode(content) == der:
            return certificate["id"]
    return None


def run(command: list[str], *, secret: bool = False, **kwargs) -> subprocess.CompletedProcess:
    result = subprocess.run(command, capture_output=True, check=False, **kwargs)
    if result.returncode != 0:
        shown = "openssl (arguments hidden)" if secret else " ".join(command)
        detail = result.stderr.decode("utf-8", "replace")
        raise RuntimeError(f"command failed: {shown}\n{detail}")
    return result


def create_distribution_certificate(token: str, signing_dir: Path, password: str) -> tuple[Path, bytes, str]:
    existing = list_all(token, "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50")
    # Leave room under Apple's distribution-certificate cap. A revoked cert cannot be
    # downloaded again; creating one we fail to cache would burn a slot.
    if len(existing) >= 3:
        names = [((item.get("attributes") or {}).get("name") or item.get("id")) for item in existing]
        raise SystemExit(
            "This team already has "
            f"{len(existing)} Apple Distribution certificates ({', '.join(map(str, names))}). "
            "Revoke an unused one in Certificates, Identifiers & Profiles, then re-run TestFlight."
        )
    key_path = signing_dir / "distribution.key"
    csr_path = signing_dir / "distribution.csr"
    run(["openssl", "genrsa", "-out", str(key_path), "2048"])
    run(
        ["openssl", "req", "-new", "-key", str(key_path), "-out", str(csr_path), "-subj", "/CN=Continuity CI Distribution"]
    )
    created = api(
        token,
        "POST",
        "/v1/certificates",
        {
            "data": {
                "type": "certificates",
                "attributes": {
                    "certificateType": "DISTRIBUTION",
                    "csrContent": csr_path.read_text(),
                },
            },
        },
    )
    der = base64.b64decode(created["data"]["attributes"]["certificateContent"])
    der_path = signing_dir / "distribution.cer"
    pem_path = signing_dir / "distribution.pem"
    p12_path = signing_dir / "distribution.p12"
    certificate_id = created["data"]["id"]
    der_path.write_bytes(der)
    run(["openssl", "x509", "-inform", "DER", "-in", str(der_path), "-out", str(pem_path)])
    export_p12(key_path, pem_path, p12_path, password)
    key_path.unlink(missing_ok=True)
    os.chmod(p12_path, 0o600)
    (signing_dir / "created-new").write_text("new\n")
    return p12_path, der, certificate_id


def export_p12(key_path: Path, pem_path: Path, p12_path: Path, password: str) -> None:
    # 3DES so `security import` on the macOS runner accepts the archive.
    run(
        [
            "openssl",
            "pkcs12",
            "-export",
            "-inkey",
            str(key_path),
            "-in",
            str(pem_path),
            "-out",
            str(p12_path),
            "-passout",
            f"pass:{password}",
            "-certpbe",
            "PBE-SHA1-3DES",
            "-keypbe",
            "PBE-SHA1-3DES",
            "-macalg",
            "sha1",
        ],
        secret=True,
    )


def ensure_certificate(token: str, signing_dir: Path, api_key: bytes) -> tuple[str, bytes]:
    password = p12_password(api_key)
    p12_path = signing_dir / "distribution.p12"
    der: bytes | None = None
    if p12_path.exists():
        try:
            der = p12_certificate_der(p12_path, password)
        except RuntimeError as error:
            print(f"Cached distribution certificate could not be read ({error}). Creating a new one.")
            der = None
    if der is not None:
        certificate_id = matching_certificate_id(token, der)
        if certificate_id:
            print(f"Reusing Apple Distribution certificate {certificate_serial(der)}")
            return certificate_id, der
        print("Cached distribution certificate is not on the team anymore. Creating a new one.")
    _, der, certificate_id = create_distribution_certificate(token, signing_dir, password)
    print(f"Created Apple Distribution certificate {certificate_serial(der)}")
    return certificate_id, der


def decode_provision_plist(data: bytes) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "profile.mobileprovision"
        source.write_bytes(data)
        commands = []
        if shutil.which("security"):
            commands.append(["security", "cms", "-D", "-i", str(source)])
        commands.append(["openssl", "cms", "-inform", "DER", "-verify", "-noverify", "-in", str(source)])
        errors = []
        for command in commands:
            result = subprocess.run(command, capture_output=True, check=False)
            if result.returncode == 0 and result.stdout.strip():
                return plistlib.loads(result.stdout)
            errors.append(result.stderr.decode("utf-8", "replace"))
        raise RuntimeError("could not decode provisioning profile: " + " | ".join(errors))


def profile_has_group(plist: dict, group: str) -> bool:
    groups = (plist.get("Entitlements") or {}).get("com.apple.security.application-groups") or []
    return group in groups


def profile_has_certificate(plist: dict, der: bytes) -> bool:
    for item in plist.get("DeveloperCertificates") or []:
        if bytes(item) == der:
            return True
    return False


def app_group_settings(group: str, key: str) -> list[dict]:
    return [{"key": key, "options": [{"key": group, "enabled": True}]}]


def ensure_app_group_capability(token: str, bundle_resource_id: str, group: str) -> None:
    capabilities = list_all(token, f"/v1/bundleIds/{bundle_resource_id}/bundleIdCapabilities?limit=50")
    current = next(
        (item for item in capabilities if (item.get("attributes") or {}).get("capabilityType") == "APP_GROUPS"),
        None,
    )
    errors = []
    for key in ("APP_GROUPS", "APP_GROUP_IDS"):
        settings = app_group_settings(group, key)
        try:
            if current is None:
                api(
                    token,
                    "POST",
                    "/v1/bundleIdCapabilities",
                    {
                        "data": {
                            "type": "bundleIdCapabilities",
                            "attributes": {"capabilityType": "APP_GROUPS", "settings": settings},
                            "relationships": {
                                "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}}
                            },
                        }
                    },
                )
            else:
                api(
                    token,
                    "PATCH",
                    f"/v1/bundleIdCapabilities/{current['id']}",
                    {
                        "data": {
                            "type": "bundleIdCapabilities",
                            "id": current["id"],
                            "attributes": {"capabilityType": "APP_GROUPS", "settings": settings},
                        }
                    },
                )
            print(f"Enabled App Groups ({key}) on bundle resource {bundle_resource_id}")
            return
        except APIError as error:
            errors.append(str(error))
    raise SystemExit("Could not enable App Groups on the App ID.\n" + "\n".join(errors))


def find_bundle_id(token: str, identifier: str) -> str:
    quoted = urllib.parse.quote(identifier)
    found = list_all(token, f"/v1/bundleIds?filter[identifier]={quoted}&limit=5")
    matches = [item for item in found if (item.get("attributes") or {}).get("identifier") == identifier]
    if not matches:
        raise SystemExit(
            f"No App ID {identifier} on this team. The TestFlight app and share extension should already exist."
        )
    return matches[0]["id"]


def profiles_named(token: str, name: str) -> list[dict]:
    quoted = urllib.parse.quote(name)
    return list_all(
        token,
        f"/v1/profiles?filter[name]={quoted}&filter[profileType]=IOS_APP_STORE&limit=20",
    )


def profile_bytes(token: str, profile_id: str) -> bytes:
    payload = api(token, "GET", f"/v1/profiles/{profile_id}")
    return base64.b64decode(payload["data"]["attributes"]["profileContent"])


def delete_profile(token: str, profile_id: str) -> None:
    try:
        api(token, "DELETE", f"/v1/profiles/{profile_id}")
    except APIError as error:
        if error.status != 404:
            raise


def create_profile(token: str, name: str, bundle_resource_id: str, certificate_id: str) -> bytes:
    created = api(
        token,
        "POST",
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
                },
            }
        },
    )
    content = (created["data"].get("attributes") or {}).get("profileContent")
    if not content:
        return profile_bytes(token, created["data"]["id"])
    return base64.b64decode(content)


def usable_profile(plist: dict, group: str, der: bytes) -> bool:
    return profile_has_group(plist, group) and profile_has_certificate(plist, der)


def ensure_profile(token: str, identifier: str, profile_name: str, certificate_id: str, der: bytes) -> bytes:
    bundle_resource_id = find_bundle_id(token, identifier)
    attempted_capability_fix = False
    conflicts = 0
    while True:
        for existing in profiles_named(token, profile_name):
            data = profile_bytes(token, existing["id"])
            plist = decode_provision_plist(data)
            if usable_profile(plist, APP_GROUP, der):
                print(f"Reusing profile {profile_name} for {identifier}")
                return data
            print(f"Replacing profile {profile_name}; it is missing the app group or this certificate.")
            delete_profile(token, existing["id"])
        try:
            data = create_profile(token, profile_name, bundle_resource_id, certificate_id)
        except APIError as error:
            if error.status == 409 and conflicts < 2:
                # A profile with this name still exists but was not returned by the filter.
                conflicts += 1
                for existing in profiles_named(token, profile_name):
                    delete_profile(token, existing["id"])
                continue
            raise
        plist = decode_provision_plist(data)
        if usable_profile(plist, APP_GROUP, der):
            print(f"Created profile {profile_name} for {identifier}")
            return data
        if attempted_capability_fix:
            entitlements = plist.get("Entitlements") or {}
            raise SystemExit(
                f"Profile {profile_name} still lacks {APP_GROUP}. Entitlements: {json.dumps(entitlements)}"
            )
        print(f"Profile {profile_name} has no {APP_GROUP}. Updating the App ID capability and regenerating.")
        for existing in profiles_named(token, profile_name):
            delete_profile(token, existing["id"])
        ensure_app_group_capability(token, bundle_resource_id, APP_GROUP)
        attempted_capability_fix = True


def install_profile(data: bytes) -> None:
    plist = decode_provision_plist(data)
    destination = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"
    destination.mkdir(parents=True, exist_ok=True)
    (destination / f"{plist['UUID']}.mobileprovision").write_bytes(data)
    print(f"Installed profile {plist.get('Name')} ({plist['UUID']})")


def release_xcconfig(profile_name: str) -> str:
    return (
        "CODE_SIGN_STYLE = Manual\n"
        "CODE_SIGN_IDENTITY = Apple Distribution\n"
        f"PROVISIONING_PROFILE_SPECIFIER = {profile_name}\n"
        f"DEVELOPMENT_TEAM = {TEAM_ID}\n"
    )


def write_export_options(path: Path, profiles: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(
            {
                "method": "app-store-connect",
                "destination": "upload",
                "signingStyle": "manual",
                "signingCertificate": "Apple Distribution",
                "teamID": TEAM_ID,
                "manageAppVersionAndBuildNumber": False,
                "provisioningProfiles": profiles,
            },
            handle,
            fmt=plistlib.FMT_XML,
        )


def import_certificate(p12: Path, password: str) -> None:
    keychain = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "continuity-signing.keychain-db"
    keychain_password = hashlib.sha256(os.urandom(32)).hexdigest()
    if keychain.exists():
        keychain.unlink()
    subprocess.run(["security", "create-keychain", "-p", keychain_password, str(keychain)], check=True)
    subprocess.run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)], check=True)
    subprocess.run(["security", "unlock-keychain", "-p", keychain_password, str(keychain)], check=True)
    subprocess.run(
        ["security", "import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"],
        check=True,
    )
    subprocess.run(
        [
            "security",
            "set-key-partition-list",
            "-S",
            "apple-tool:,apple:,codesign:",
            "-s",
            "-k",
            keychain_password,
            str(keychain),
        ],
        check=True,
    )
    subprocess.run(
        ["security", "list-keychains", "-d", "user", "-s", str(keychain), "/Library/Keychains/System.keychain"],
        check=True,
    )
    subprocess.run(["security", "default-keychain", "-s", str(keychain)], check=True)
    identities = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning", str(keychain)],
        capture_output=True,
        text=True,
        check=True,
    )
    print(identities.stdout)
    if "Apple Distribution" not in identities.stdout:
        raise SystemExit("The distribution certificate imported, but codesign cannot see an Apple Distribution identity.")


def main() -> None:
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    key_path = Path(os.environ.get("ASC_KEY_PATH", Path.home() / "private_keys" / f"AuthKey_{key_id}.p8"))
    api_key = key_path.read_bytes()
    signing_dir = ROOT / ".signing"
    signing_dir.mkdir(parents=True, exist_ok=True)
    token = make_token(key_id, issuer_id, key_path)
    certificate_id, der = ensure_certificate(token, signing_dir, api_key)
    profiles: dict[str, str] = {}
    for identifier, profile_name, xcconfig_rel in TARGETS:
        data = ensure_profile(token, identifier, profile_name, certificate_id, der)
        install_profile(data)
        xcconfig = ROOT / xcconfig_rel
        xcconfig.parent.mkdir(parents=True, exist_ok=True)
        xcconfig.write_text(release_xcconfig(profile_name))
        profiles[identifier] = profile_name
    write_export_options(ROOT / "Signing" / "ExportOptions.plist", profiles)
    import_certificate(signing_dir / "distribution.p12", p12_password(api_key))


if __name__ == "__main__":
    main()
