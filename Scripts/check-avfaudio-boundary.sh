#!/usr/bin/env bash
# Enforces the AVFAudio exception boundary in the Playback module.
#
# AVFAudio reports precondition failures (play() on a stopped engine, a past play(at:) time,
# a bad scheduleSegment range, an unconvertible connect format, start() with an invalid
# output format) as Objective-C exceptions, which Swift cannot catch — the process aborts.
# Every such call must therefore go through the `guarded*` wrappers in
# Packages/ContinuityKit/Sources/Playback/AVFAudioGuard.swift, which run it inside the
# AVFAudioShim @try/@catch. This script fails CI if a raw call appears anywhere else in
# Playback, so the boundary can't erode one convenient `.play()` at a time.
#
# Usage: Scripts/check-avfaudio-boundary.sh   (exit 0 = clean, 1 = violations listed)
set -eu

cd "$(dirname "$0")/.."
PLAYBACK=Packages/ContinuityKit/Sources/Playback
GUARD="$PLAYBACK/AVFAudioGuard.swift"
SHIM=Packages/ContinuityKit/Sources/AVFAudioShim/AVFAudioShim.m

status=0

if [ ! -f "$GUARD" ] || [ ! -f "$SHIM" ]; then
  echo "error: AVFAudio exception boundary files missing ($GUARD, $SHIM)" >&2
  exit 1
fi

# Player-node methods: only the two node fields in Deck (and the generic `player` parameter of
# Deck.scheduleSegment) can be AVAudioPlayerNode receivers. `Deck.play()` etc. are Swift
# methods and are fine — they are the guarded funnel. `play()`/`play(at:` are matched exactly
# so the public `Player.play(tracks:startAt:)` never trips this.
NODE_RE='\b(vocalsPlayer|accompPlayer|player|node)\.(play\(\)|play\(at:|pause\(\)|stop\(\)|scheduleFile\(|scheduleSegment\(|scheduleBuffer\(|prepare\()'
# Engine graph/lifecycle calls that raise.
ENGINE_RE='\bengine\.(start|attach|detach|connect|disconnectNodeOutput|disconnectNodeInput|prepare|reset)\('

violations=$(grep -rnE --include='*.swift' "$NODE_RE|$ENGINE_RE" "$PLAYBACK" \
  | grep -v "^$GUARD:" \
  | grep -vE '^\S+:[0-9]+:\s*///?' || true)

if [ -n "$violations" ]; then
  echo "error: raw AVFAudio node/engine calls outside $GUARD (route them through the guarded* wrappers):" >&2
  echo "$violations" >&2
  status=1
fi

# The shim may only be imported by the guard file.
importers=$(grep -rln --include='*.swift' '^import AVFAudioShim' "$PLAYBACK" | grep -v "^$GUARD$" || true)
if [ -n "$importers" ]; then
  echo "error: AVFAudioShim imported outside $GUARD:" >&2
  echo "$importers" >&2
  status=1
fi

# Every guarded wrapper must actually be wrapped in AVFAudioGuard.attempt.
raw_in_guard=$(grep -nE "$NODE_RE|$ENGINE_RE|\bself\.(play\(\)|play\(at:|pause\(\)|stop\(\)|scheduleFile\(|scheduleSegment\(|scheduleBuffer\(|start\(\)|attach\(|connect\(|disconnectNodeOutput\()" "$GUARD" \
  | grep -vE '^\s*[0-9]+:\s*///?' || true)
attempts=$(grep -c 'AVFAudioGuard.attempt(' "$GUARD" || true)
raw_count=$(printf '%s\n' "$raw_in_guard" | grep -c . || true)
if [ "$raw_count" -gt "$attempts" ]; then
  echo "error: $GUARD has $raw_count raw AVFAudio calls but only $attempts AVFAudioGuard.attempt wrappers" >&2
  echo "$raw_in_guard" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "AVFAudio boundary OK: all node/engine calls in $PLAYBACK go through $GUARD"
fi
exit "$status"
