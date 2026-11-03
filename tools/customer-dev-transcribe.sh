#!/usr/bin/env bash
# Transcribe an interview recording locally and drop the raw transcript into docs/customer-dev/interviews/.
# Usage: tools/customer-dev-transcribe.sh <recording> [first-last] [YYYY-MM-DD]
# Any format ffmpeg reads (ogg, m4a, mp4, mov, wav). Uses mlx-whisper (whisper-large-v3-turbo) from ~/Code/Wythin/.venv313 (override with WYTHIN_VENV).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$1"; SLUG="${2:-$(basename "${IN%.*}" | tr 'A-Z ' 'a-z-')}"; DAY="${3:-$(date +%F)}"
OUT="$ROOT/docs/customer-dev/interviews/$DAY-$SLUG.md"
TMP="$(mktemp -d)"
ffmpeg -v error -y -i "$IN" -ar 16000 -ac 1 "$TMP/a.wav"
PY="${WYTHIN_VENV:-$HOME/Code/Wythin/.venv313}/bin/python"
"$PY" - "$TMP/a.wav" "$IN" "$OUT" <<'PY'
import sys, mlx_whisper
wav, src, out = sys.argv[1:]
r = mlx_whisper.transcribe(wav, path_or_hf_repo="mlx-community/whisper-large-v3-turbo")
with open(out, "a") as f:
    f.write(f"\n\n## Raw transcript — {src.split('/')[-1]} (language: {r.get('language')})\n\n")
    for s in r["segments"]:
        f.write(f"[{int(s['start'])//60:02d}:{int(s['start'])%60:02d}] {s['text'].strip()}\n")
print(out)
PY
rm -rf "$TMP"
