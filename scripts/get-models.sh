#!/usr/bin/env bash
# Download the three models stenographr needs into the models folder (default ~/.local/share/stenographr/models,
# the config default; pass another folder as the first argument, or -y/--yes to skip the question).
# Prints each download's size, skips what is already there, asks before downloading, checks sha256 when one is set.
# Needs curl and tar (bzip2). Nothing else is touched; this is the only part of stenographr that uses the network.
set -euo pipefail

BASE=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models
yes=0; dir=""
for a in "$@"; do
  case $a in
    -y|--yes) yes=1 ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) dir=$a ;;
  esac
done
dir=${dir:-${STENO_MODELS:-$HOME/.local/share/stenographr/models}}

# name | what it is | file to download | what exists when it is installed | kind (file|tar) | sha256 ("" = not known, not checked)
MODELS=(
  "silero_vad|voice activity detection (cuts recordings into utterances)|silero_vad.onnx|silero_vad.onnx|file|"
  "parakeet|Parakeet TDT 0.6B v2 int8 (the final text)|sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2|sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8|tar|"
  "nemotron|Nemotron streaming 0.6B int8 (the live preview)|sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2|sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25|tar|"
)

size_of() {   # bytes from the server, or empty
  curl -sIL --max-time 20 "$1" | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}'
}
human() { awk -v b="${1:-0}" 'BEGIN { if (b == 0) print "size unknown"; else printf "%.1f MB\n", b/1048576 }'; }

mkdir -p "$dir"
todo=()
echo "models folder: $dir"
for m in "${MODELS[@]}"; do
  IFS='|' read -r name what file present kind sha <<<"$m"
  if [[ -e $dir/$present ]]; then echo "  have     $name: $present"; continue; fi
  echo "  missing  $name: $what, $(human "$(size_of "$BASE/$file")")"
  todo+=("$m")
done
[[ ${#todo[@]} == 0 ]] && { echo "nothing to download"; exit 0; }

if [[ $yes == 0 ]]; then
  [[ -t 0 ]] || { echo "not a terminal: rerun with -y to download without asking" >&2; exit 1; }
  read -r -p "download the ${#todo[@]} missing model(s) from github.com? [y/N] " ans
  [[ $ans == y || $ans == Y ]] || { echo "nothing downloaded"; exit 0; }
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for m in "${todo[@]}"; do
  IFS='|' read -r name what file present kind sha <<<"$m"
  echo "downloading $name ..."
  curl -fL --progress-bar -o "$tmp/$file" "$BASE/$file"
  if [[ -n $sha ]]; then
    echo "$sha  $tmp/$file" | sha256sum -c --quiet - || { echo "sha256 mismatch for $file, not installed" >&2; exit 1; }
  else
    echo "  sha256: not known for $file, not checked ($(sha256sum "$tmp/$file" | cut -c1-16)...)"
  fi
  if [[ $kind == tar ]]; then tar xjf "$tmp/$file" -C "$dir"; else mv "$tmp/$file" "$dir/$file"; fi
  [[ -e $dir/$present ]] || { echo "$file did not give $present" >&2; exit 1; }
done
echo "done"
