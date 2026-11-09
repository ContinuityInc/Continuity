#!/usr/bin/env bash
# Enforces the YouTubeKit import boundary.
#
# Stream extraction is brittle and pinned exact: — Continuity only talks to YouTubeKit
# through `AudioStreamResolving` / `YouTubeStreamResolver`. Selection policy and host
# allowlisting live in ContinuityCore so an extractor swap is one target. This script
# fails CI if `import YouTubeKit` appears anywhere else, or if the SPM pin floats off
# `exact:`.
#
# App Store cut (`release/app-store`): Package.swift has no YouTubeKit dependency. In that
# case the script verifies total absence (no import / product / package pin) and exits 0.
#
# Usage: Scripts/check-youtubekit-boundary.sh   (exit 0 = clean, 1 = violations listed)
set -eu

cd "$(dirname "$0")/.."

ALLOWLIST='Packages/ContinuityKit/Sources/Ingest/YouTubeStreamResolver.swift'
PACKAGE=Packages/ContinuityKit/Package.swift

status=0

if [ ! -f "$PACKAGE" ]; then
  echo "error: ContinuityKit Package.swift missing ($PACKAGE)" >&2
  exit 1
fi

# App Store line strips YouTubeKit entirely. Confirm it stayed gone.
if ! grep -qE 'YouTubeKit' "$PACKAGE"; then
  importers=$(grep -rln --include='*.swift' '^import YouTubeKit$' . \
    | grep -v '^\./\.build/' \
    | grep -v '/\.build/' \
    || true)
  if [ -n "$importers" ]; then
    echo "error: YouTubeKit imported on App Store cut (Package.swift has no YouTubeKit):" >&2
    echo "$importers" >&2
    exit 1
  fi
  if grep -q 'YouTubeKit' Packages/ContinuityKit/Package.resolved 2>/dev/null; then
    echo "error: Package.resolved still pins YouTubeKit on App Store cut" >&2
    exit 1
  fi
  echo "YouTubeKit absent (App Store cut) — boundary OK"
  exit 0
fi

if [ ! -f "$ALLOWLIST" ]; then
  echo "error: YouTubeKit allowlist file missing ($ALLOWLIST)" >&2
  exit 1
fi

if ! grep -q '^import YouTubeKit$' "$ALLOWLIST"; then
  echo "error: $ALLOWLIST must import YouTubeKit (it is the sole allowed site)" >&2
  status=1
fi

# Any other Swift file importing YouTubeKit is leakage past AudioStreamResolving.
importers=$(grep -rln --include='*.swift' '^import YouTubeKit$' . \
  | grep -v '^\./\.build/' \
  | grep -v '/\.build/' \
  | grep -v "^$ALLOWLIST$" \
  | grep -v "^\./$ALLOWLIST$" \
  || true)

if [ -n "$importers" ]; then
  echo "error: YouTubeKit imported outside $ALLOWLIST (route extraction through AudioStreamResolving):" >&2
  echo "$importers" >&2
  status=1
fi

# Qualified YouTubeKit.* type use outside the allowlist (even without a fresh import via
# accidental typealias / same-module leakage) is also a boundary break.
type_refs=$(grep -rn --include='*.swift' '\bYouTubeKit\.' . \
  | grep -v '^\./\.build/' \
  | grep -v '/\.build/' \
  | grep -v "^$ALLOWLIST:" \
  | grep -v "^\./$ALLOWLIST:" \
  | grep -vE 'Package\.swift:' \
  | grep -vE '^\S+:[0-9]+:\s*///?' \
  || true)

if [ -n "$type_refs" ]; then
  echo "error: YouTubeKit type references outside $ALLOWLIST:" >&2
  echo "$type_refs" >&2
  status=1
fi

# Keep the exact: pin — branch:/from:/upToNextMajor would silently track upstream HEAD.
if ! grep -qE 'package\(url: "https://github\.com/alexeichhorn/YouTubeKit", exact:' "$PACKAGE"; then
  echo "error: YouTubeKit must stay exact:-pinned in $PACKAGE (no branch:/from:/range)" >&2
  status=1
fi

# Only the Ingest target may depend on the YouTubeKit product.
product_lines=$(grep -n 'product(name: "YouTubeKit"' "$PACKAGE" || true)
product_count=$(printf '%s\n' "$product_lines" | grep -c . || true)
if [ "$product_count" -ne 1 ]; then
  echo "error: expected exactly one YouTubeKit product dependency in $PACKAGE (Ingest only):" >&2
  echo "$product_lines" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "YouTubeKit boundary OK: sole import in $ALLOWLIST; exact: pin intact"
fi
exit "$status"
