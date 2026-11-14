#!/usr/bin/env bash
# Enforces the AVFAudio exception boundary in the Playback module.
#
# AVFAudio reports precondition failures (play() on a stopped engine, a past play(at:) time,
# a bad scheduleSegment range, an unconvertible connect format, start() with an invalid
# output format) as Objective-C exceptions, which Swift cannot catch — the process aborts.
# Every such call must therefore go through the `guarded*` wrappers in
# Packages/ContinuityKit/Sources/Playback/AVFAudioGuard.swift, which run it inside the
# AVFAudioShim @try/@catch. This script fails CI if a raw call appears anywhere else in
# Playback, so the boundary can't erode one convenient `.play()` at a time. It also locks
# AVAudioFile(forReading:) and timePitch rate/pitch writes to the guard, and requires
# recoverPlayback to stay behind scheduleRecoverPlayback's deferred hop.
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

# AVAudioFile(forReading:) can raise on corrupt/truncated AAC — only guardedOpen may call it.
file_opens=$(grep -rnE --include='*.swift' 'AVAudioFile\(forReading:' "$PLAYBACK" \
  | grep -v "^$GUARD:" \
  | grep -vE '^\S+:[0-9]+:\s*///?' || true)
if [ -n "$file_opens" ]; then
  echo "error: raw AVAudioFile(forReading:) outside $GUARD (use AVAudioFile.guardedOpen):" >&2
  echo "$file_opens" >&2
  status=1
fi

# timePitch.rate / .pitch writes raise on out-of-range / non-finite values during graph churn.
# Deck setters must go through guardedSetRate / guardedSetPitch.
pitch_writes=$(grep -rnE --include='*.swift' '\b(timePitch|self)\.(rate|pitch)\s*=' "$PLAYBACK" \
  | grep -v "^$GUARD:" \
  | grep -vE '^\S+:[0-9]+:\s*///?' || true)
if [ -n "$pitch_writes" ]; then
  echo "error: raw timePitch rate/pitch writes outside $GUARD (use guardedSetRate/guardedSetPitch):" >&2
  echo "$pitch_writes" >&2
  status=1
fi

# recoverPlayback must only run from the deferred scheduleRecoverPlayback path — a sync call
# from a NotificationCenter main-queue observer re-enters mid-start and is a crash class.
# Drop comment lines, the definition, string literals (e.g. startCurrentDeck context labels),
# and the one allowed call site inside scheduleRecoverPlayback's asyncAfter.
recover_calls=$(grep -rnE --include='*.swift' '\brecoverPlayback\s*\(' "$PLAYBACK" \
  | grep -vE '^\S+:[0-9]+:\s*///?' \
  | grep -vE 'func recoverPlayback\s*\(' \
  | grep -v '"' \
  | grep -vE 'Player\+AudioSession\.swift:[0-9]+:\s*self\.recoverPlayback\(force:' || true)
if [ -n "$recover_calls" ]; then
  echo "error: recoverPlayback called outside scheduleRecoverPlayback's deferred block:" >&2
  echo "$recover_calls" >&2
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
  echo "AVFAudio boundary OK: node/engine/file/timePitch calls in $PLAYBACK go through $GUARD; recoverPlayback stays deferred"
fi
exit "$status"
