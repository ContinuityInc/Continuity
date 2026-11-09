#!/usr/bin/env python3
"""Fill the App Store Connect fields that block Add for Review.

Uses the existing ASC API key (Admin role). Sets:

- Content rights declaration
- Primary category (Music)
- Privacy Policy URL (App Info localization)
- Support URL + listing copy (version localization)
- App Review contact (first/last/email) and demoAccountRequired=false
- Latest VALID 1.0.x build, if one exists

Does not touch screenshots (uploads-in-progress on a phone will 409 if we race them).
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

try:
    import jwt
except ImportError:
    sys.exit("PyJWT is required (pip install PyJWT cryptography)")

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "com.sanylax.continuity")
APP_ID_HINT = os.environ.get("ASC_APP_ID", "6792130853")
STORE_VERSION_PREFIX = os.environ.get("ASC_VERSION_PREFIX", "1.0")

CONTACT_FIRST = os.environ.get("ASC_CONTACT_FIRST", "Santosh")
CONTACT_LAST = os.environ.get("ASC_CONTACT_LAST", "Lakshman")
CONTACT_EMAIL = os.environ.get("ASC_CONTACT_EMAIL", "sanylax01@gmail.com")
CONTACT_PHONE = os.environ.get("ASC_CONTACT_PHONE", "").strip()

COPYRIGHT = os.environ.get("ASC_COPYRIGHT", "2026 Santosh Lakshman")
SUBTITLE = "Beatmatched DJ blends"
KEYWORDS = "music,dj,crossfade,blend,beatmatch,player,stems,transition,mix"
DESCRIPTION = """Continuity is a music player whose song changes are DJ blends.

Every skip is beatmatched, loudness-leveled, and — when stems are ready — vocal-aware, so the next track arrives like a mix instead of a cut.

Import the audio you already own from the Files app. Analysis (tempo, key, loudness) and stem separation run on your iPhone. There are no accounts, no tracking, and no cloud library.

Continuity is built for iPhone."""
REVIEW_NOTES = """No account or sign-in — leave Sign-in required off. Continuity is a local music player: tap + and import audio from the Files app. Demo playlists are synthesized tones, not commercial recordings. Stem separation (HT-Demucs) runs on-device; the model file downloads once from Hugging Face. Please skip a track during playback to hear a blend."""

PRIMARY_CATEGORY = "MUSIC"


def die(message: str, details: Any = None) -> None:
    print(f"error: {message}", file=sys.stderr)
    if details is not None:
        print(json.dumps(details, indent=2)[:4000], file=sys.stderr)
    sys.exit(1)


def load_private_key() -> str:
    path = os.environ.get("ASC_KEY_P8_PATH", "")
    raw = os.environ.get("ASC_KEY_P8", "")
    if path:
        text = Path(path).read_text()
    elif raw:
        text = raw
        if "BEGIN" not in text:
            import base64

            text = base64.b64decode(text).decode()
    else:
        die("ASC_KEY_P8_PATH or ASC_KEY_P8 is required")
    if "BEGIN" not in text:
        die("ASC key does not look like a PEM private key")
    return text


def make_token() -> str:
    key_id = os.environ.get("ASC_KEY_ID", "")
    issuer = os.environ.get("ASC_ISSUER_ID", "")
    if not key_id or not issuer:
        die("ASC_KEY_ID and ASC_ISSUER_ID are required")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"},
        load_private_key(),
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


TOKEN = ""


def compact(attrs: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in attrs.items() if value is not None}


def api(
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    params: dict[str, str] | None = None,
    allow_http: tuple[int, ...] = (),
) -> Any:
    url = path if path.startswith("http") else API + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params, doseq=True)
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if data is not None else {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"body": raw.decode("utf-8", "replace")[:2000]}
        if exc.code in allow_http:
            return parsed
        errors = parsed.get("errors") or parsed
        die(f"{method} {url} -> HTTP {exc.code}", errors)
        return None  # unreachable


def first(items: list[dict[str, Any]], predicate=None) -> dict[str, Any] | None:
    for item in items:
        if predicate is None or predicate(item):
            return item
    return None


def url_ok(url: str) -> bool:
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "ContinuityASC/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return 200 <= resp.status < 400
    except Exception:
        return False


def pick_public_url(candidates: list[str]) -> str:
    for url in candidates:
        print(f"checking {url}")
        if url_ok(url):
            return url
    # Last resort: still return the first candidate so ASC has *a* URL.
    print("warning: none of the candidate URLs returned 200; using the last anyway")
    return candidates[-1]


def find_app() -> dict[str, Any]:
    if APP_ID_HINT:
        resp = api("GET", f"/v1/apps/{APP_ID_HINT}", allow_http=(404,))
        data = (resp or {}).get("data")
        if data:
            return data
        print(f"app id {APP_ID_HINT} not found, falling back to bundle id")
    resp = api("GET", "/v1/apps", params={"filter[bundleId]": BUNDLE_ID})
    app = first(resp.get("data") or [])
    if not app:
        die(f"no app with bundle id {BUNDLE_ID}")
    return app


def editable_app_info(app_id: str) -> dict[str, Any]:
    resp = api("GET", f"/v1/apps/{app_id}/appInfos")
    infos = resp.get("data") or []
    preferred_states = {
        "PREPARE_FOR_SUBMISSION",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "METADATA_REJECTED",
        "WAITING_FOR_REVIEW",
        "INVALID_BINARY",
    }
    info = first(infos, lambda i: i.get("attributes", {}).get("appStoreState") in preferred_states)
    if info is None:
        info = first(infos)
    if info is None:
        die("no appInfos for app")
    return info


def localization(path: str, locale: str = "en-US") -> dict[str, Any]:
    resp = api("GET", path)
    items = resp.get("data") or []
    loc = first(items, lambda i: i.get("attributes", {}).get("locale") == locale) or first(items)
    if loc is None:
        die(f"no localizations at {path}")
    return loc


def latest_ios_version(app_id: str) -> dict[str, Any]:
    resp = api(
        "GET",
        f"/v1/apps/{app_id}/appStoreVersions",
        params={
            "filter[platform]": "IOS",
            "limit": "20",
            "sort": "-versionString",
        },
    )
    versions = resp.get("data") or []
    editable = {
        "PREPARE_FOR_SUBMISSION",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "METADATA_REJECTED",
        "INVALID_BINARY",
    }
    ver = first(versions, lambda v: v.get("attributes", {}).get("appStoreState") in editable)
    if ver is None:
        ver = first(versions)
    if ver is None:
        die("no iOS App Store versions — create 1.0.0 in App Store Connect first")
    return ver


def matching_build(app_id: str, version_string: str) -> dict[str, Any] | None:
    if not version_string.startswith(STORE_VERSION_PREFIX):
        print(
            f"editable version is {version_string}, not {STORE_VERSION_PREFIX}.x — "
            "refusing to attach a YouTube/TestFlight 0.1 build"
        )
        return None
    resp = api(
        "GET",
        "/v1/builds",
        params={
            "filter[app]": app_id,
            "filter[processingState]": "VALID",
            "sort": "-uploadedDate",
            "limit": "25",
            "include": "preReleaseVersion",
        },
    )
    included = {item["id"]: item for item in resp.get("included") or []}
    for build in resp.get("data") or []:
        pre_id = ((build.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
        pre = included.get(pre_id.get("id", ""))
        pre_version = (pre or {}).get("attributes", {}).get("version", "")
        if pre_version == version_string:
            return build
    return None


def main() -> None:
    global TOKEN, CONTACT_PHONE
    TOKEN = make_token()

    sha = os.environ.get("GITHUB_SHA", "main")
    privacy_override = os.environ.get("PRIVACY_URL", "").strip()
    support_override = os.environ.get("SUPPORT_URL", "").strip()
    privacy_url = privacy_override or pick_public_url(
        [
            "https://continuityinc.github.io/Continuity/privacy/",
            f"https://cdn.jsdelivr.net/gh/ContinuityInc/Continuity@{sha}/docs/site/privacy/index.html",
            "https://cdn.jsdelivr.net/gh/ContinuityInc/Continuity@main/docs/site/privacy/index.html",
            "https://github.com/ContinuityInc/Continuity/blob/main/PRIVACY.md",
        ]
    )
    support_url = support_override or pick_public_url(
        [
            "https://continuityinc.github.io/Continuity/support/",
            f"https://cdn.jsdelivr.net/gh/ContinuityInc/Continuity@{sha}/docs/site/support/index.html",
            "https://github.com/ContinuityInc/Continuity/issues",
        ]
    )
    print(f"privacy URL: {privacy_url}")
    print(f"support URL: {support_url}")

    app = find_app()
    app_id = app["id"]
    print(f"app {app.get('attributes', {}).get('name')} id={app_id}")

    if not CONTACT_PHONE:
        beta = api("GET", f"/v1/apps/{app_id}/betaAppReviewDetail", allow_http=(404,))
        beta_phone = ((beta or {}).get("data") or {}).get("attributes", {}).get("phoneNumber") or ""
        if beta_phone:
            CONTACT_PHONE = beta_phone
            print("using phone number already on file for TestFlight review")
        else:
            print("no phone number on file — App Review contact phone may still be required in the UI")

    # Content Rights lives on the app, not the version.
    api(
        "PATCH",
        f"/v1/apps/{app_id}",
        {
            "data": {
                "type": "apps",
                "id": app_id,
                "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"},
            }
        },
    )
    print("content rights: DOES_NOT_USE_THIRD_PARTY_CONTENT")

    info = editable_app_info(app_id)
    info_id = info["id"]
    print(f"appInfo {info_id} state={info.get('attributes', {}).get('appStoreState')}")

    api(
        "PATCH",
        f"/v1/appInfos/{info_id}",
        {
            "data": {
                "type": "appInfos",
                "id": info_id,
                "relationships": {
                    "primaryCategory": {
                        "data": {"type": "appCategories", "id": PRIMARY_CATEGORY}
                    }
                },
            }
        },
    )
    print(f"primary category: {PRIMARY_CATEGORY}")

    info_loc = localization(f"/v1/appInfos/{info_id}/appInfoLocalizations")
    api(
        "PATCH",
        f"/v1/appInfoLocalizations/{info_loc['id']}",
        {
            "data": {
                "type": "appInfoLocalizations",
                "id": info_loc["id"],
                "attributes": {
                    "privacyPolicyUrl": privacy_url,
                    "subtitle": SUBTITLE,
                },
            }
        },
    )
    print(f"privacyPolicyUrl set on {info_loc.get('attributes', {}).get('locale')}")

    version = latest_ios_version(app_id)
    version_id = version["id"]
    version_string = version.get("attributes", {}).get("versionString", "")
    version_state = version.get("attributes", {}).get("appStoreState", "")
    print(f"appStoreVersion {version_string} {version_state} id={version_id}")

    loc = localization(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    listing_attrs = compact(
        {
            "description": DESCRIPTION.strip(),
            "keywords": KEYWORDS,
            "supportUrl": support_url,
        }
    )
    api(
        "PATCH",
        f"/v1/appStoreVersionLocalizations/{loc['id']}",
        {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc["id"],
                "attributes": listing_attrs,
            }
        },
    )
    print(f"listing copy + supportUrl set on {loc.get('attributes', {}).get('locale')}")

    review_rel = ((version.get("relationships") or {}).get("appStoreReviewDetail") or {}).get("data")
    review_attrs: dict[str, Any] = {
        "contactFirstName": CONTACT_FIRST,
        "contactLastName": CONTACT_LAST,
        "contactEmail": CONTACT_EMAIL,
        "demoAccountRequired": False,
        "notes": REVIEW_NOTES,
    }
    if CONTACT_PHONE:
        review_attrs["contactPhone"] = CONTACT_PHONE

    if review_rel and review_rel.get("id"):
        detail_data = {"id": review_rel["id"]}
    else:
        detail = api(
            "GET",
            f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail",
            allow_http=(404,),
        )
        detail_data = (detail or {}).get("data")

    if detail_data and detail_data.get("id"):
        api(
            "PATCH",
            f"/v1/appStoreReviewDetails/{detail_data['id']}",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "id": detail_data["id"],
                    "attributes": review_attrs,
                }
            },
        )
        print(f"patched review contact {CONTACT_FIRST} {CONTACT_LAST}; sign-in not required")
    else:
        api(
            "POST",
            "/v1/appStoreReviewDetails",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": review_attrs,
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    },
                }
            },
        )
        print(f"created review contact {CONTACT_FIRST} {CONTACT_LAST}; sign-in not required")

    build = matching_build(app_id, version_string)
    version_patch_attrs: dict[str, Any] = {"copyright": COPYRIGHT}
    version_patch: dict[str, Any] = {
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "attributes": version_patch_attrs,
        }
    }
    if build:
        version_patch["data"]["relationships"] = {
            "build": {"data": {"type": "builds", "id": build["id"]}}
        }
        print(f"attaching build {build.get('attributes', {}).get('version')} id={build['id']}")
    else:
        print(
            "no VALID 1.0.x build to attach. Run Actions → TestFlight on "
            "cursor/app-store-publish-2283 (the store cut). Do not submit a 0.1.0 YouTube build."
        )
    api("PATCH", f"/v1/appStoreVersions/{version_id}", version_patch)
    print("copyright set" + (" and build attached" if build else ""))

    print("done. Remaining in App Store Connect (phone UI):")
    print("  • wait until screenshot uploads finish, or re-upload from a computer")
    print("  • App Privacy questionnaire: No data collected → Publish")
    print("  • then Add for Review")


if __name__ == "__main__":
    main()
