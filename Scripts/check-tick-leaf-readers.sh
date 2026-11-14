#!/usr/bin/env bash
# Enforces the 20 Hz leaf-view rule for Player tick-derived fields.
#
# Player.tick() publishes `position` / `transitionProgress` (and derived
# `displayProgress` / `secondsUntilTransition` / `transitionCountdownSeconds`) at up to
# 20 Hz. Only tiny leaf views may observe those fields — parent bodies that host the
# backdrop must not re-evaluate on every tick (playback jetsam / Liquid Glass audit,
# CLAUDE.md performance invariants).
#
# Allowlisted leaf files (structs they host):
#   App/Continuity/Views/NowPlayingView.swift
#     — TrackProgressRing (displayProgress), ScrubberBar (position)
#   App/Continuity/Views/MiniPlayerView.swift
#     — MiniProgressLine (displayProgress)
#   App/Continuity/Views/TransitionVisualizationView.swift
#     — BlendPlayhead (transitionProgress), TransitionCountdownPill (transitionCountdownSeconds)
#
# Usage: Scripts/check-tick-leaf-readers.sh   (exit 0 = clean, 1 = violations listed)
set -eu

cd "$(dirname "$0")/.."

SEARCH_ROOT=App/Continuity
FIELD_RE='\bplayer\.(position|displayProgress|transitionProgress|secondsUntilTransition|transitionCountdownSeconds)\b'

ALLOWLIST=(
  "App/Continuity/Views/NowPlayingView.swift"
  "App/Continuity/Views/MiniPlayerView.swift"
  "App/Continuity/Views/TransitionVisualizationView.swift"
)

status=0

if [ ! -d "$SEARCH_ROOT" ]; then
  echo "error: tick-leaf search root missing ($SEARCH_ROOT)" >&2
  exit 1
fi

for allowed in "${ALLOWLIST[@]}"; do
  if [ ! -f "$allowed" ]; then
    echo "error: allowlisted leaf file missing ($allowed)" >&2
    status=1
  fi
done
if [ "$status" -ne 0 ]; then
  exit 1
fi

# Collect reads of tick-derived Player fields under the app target.
hits=$(grep -rnE --include='*.swift' "$FIELD_RE" "$SEARCH_ROOT" || true)

# Drop allowlisted leaf files, then drop comment-only lines (/// docs or // comments).
filtered="$hits"
for allowed in "${ALLOWLIST[@]}"; do
  filtered=$(printf '%s\n' "$filtered" | grep -v "^${allowed}:" || true)
done
filtered=$(printf '%s\n' "$filtered" | grep -vE '^\S+:[0-9]+:\s*///?' || true)

if [ -n "$filtered" ]; then
  echo "error: Player tick-field readers outside the 20 Hz leaf allowlist:" >&2
  echo "  Allowed files:" >&2
  for allowed in "${ALLOWLIST[@]}"; do
    echo "    - $allowed" >&2
  done
  echo "  Violations (move the read into a leaf, or extend the allowlist deliberately):" >&2
  echo "$filtered" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Tick-leaf readers OK: player.(position|displayProgress|transitionProgress|secondsUntilTransition|transitionCountdownSeconds) in $SEARCH_ROOT only appear in:"
  for allowed in "${ALLOWLIST[@]}"; do
    echo "  - $allowed"
  done
fi
exit "$status"
