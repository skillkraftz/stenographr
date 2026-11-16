#!/usr/bin/env bash
# Regenerates every picture in docs/img (the README's media). Run it in the lab; the lab works on a copy, so collect the result:
#   hyperbeam lab run --why "stenographr media" --collect docs/img -- bash docs/make-media.sh   (then copy the collected files into docs/img)
# Uses only the fake engine and the fakes in tests/fakebin (no microphone, model, real transcripts or real paths).
# Needs inkscape (SVG -> PNG) and Pillow (GIFs). Writes only under docs/img; everything else is in a temp dir.
set -u
DOCS=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$DOCS/../tests/lib.sh"
. "$HERE/lib-dictation.sh"
IMG=$DOCS/img; mkdir -p "$IMG"; S=$W/svg; mkdir -p "$S"
command -v inkscape >/dev/null || { echo "need inkscape"; exit 2; }
PILPY=python3; "$PILPY" -c 'import PIL' 2>/dev/null || { uv pip install -q -p "$PY" pillow && PILPY=$PY; }
export S IMG PILPY

# a Textual app that shows fixed text (a terminal or tmux pane stand-in), saved as SVG: termshot NAME WIDTH HEIGHT  (text on stdin)
cat > "$W/termshot.py" <<'PY'
import asyncio, sys
from textual.app import App
from textual.widgets import Static
name, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
text = sys.stdin.read().rstrip("\n")
class T(App):
    TITLE = sys.argv[4] if len(sys.argv) > 4 else "terminal"
    CSS = "Static { padding: 0 1; }"
    def compose(self): yield Static(text, markup=True)
async def main():
    app = T()
    async with app.run_test(size=(w, h)) as pilot:
        await pilot.pause(0.2)
        open(f"{sys.argv[5] if len(sys.argv) > 5 else '.'}/{name}.svg", "w").write(app.export_screenshot())
asyncio.run(main())
PY
termshot() { "$PY" "$W/termshot.py" "$1" "$2" "$3" "${4:-terminal}" "$S"; }
png() { inkscape "$S/$1.svg" -o "$IMG/$2.png" -w "${3:-800}" >/dev/null 2>&1 || { echo "inkscape failed on $1"; exit 1; }; }

echo "== live: GIF and sizes"
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude' FAKE_PANE_FILE=$W/pane
PHRASES="so the plan is|to ship the readme|with pictures today"; CLEAN="So the plan is to ship the README with pictures today."
mrun() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT=$PHRASES FAKE_ENGINE_CLEAN_TEXT=$CLEAN FAKE_ENGINE_CLEAN_SECONDS=100 FAKE_ENGINE_COUNT=$W/count; "$PY" -c "$LPRE$UPRE$UPRE2
$1" ); }
mrun '
async def main():
    shots = os.environ["S"]; n = [0]
    async def snap(pilot, name, wait=0.3):
        await pilot.pause(wait); n[0] += 1
        open(f"{shots}/{tag}-{n[0]:02d}-{name}.svg", "w").write(app.export_screenshot())
    for w, h in ((80, 24), (85, 12), (40, 30)):
        global app
        app = LiveApp(cfg, log, "cpu"); tag = f"{w}x{h}"
        async with app.run_test(size=(w, h)) as pilot:
            n[0] = 0
            await until(pilot, lambda: app.phase == "ready"); await snap(pilot, "ready")
            await pilot.press("enter"); await until(pilot, lambda: app.phase == "recording"); await snap(pilot, "recording0")
            await until(pilot, lambda: len(logtext(app)) == 1); await snap(pilot, "recording1")
            go(2); await until(pilot, lambda: len(logtext(app)) == 2); await snap(pilot, "recording2")
            go(3); await until(pilot, lambda: len(logtext(app)) == 3); await snap(pilot, "recording3")
            await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await snap(pilot, "review")
            await pilot.press("y"); await until(pilot, lambda: app.phase == "ready"); await snap(pilot, "copied", 0.4)
            await pilot.press("q"); await pilot.pause(0.2)
            os.system(f"rm -f {W}/gate/go*")
asyncio.run(main())
' > "$W/ui.out" 2>&1
[[ -s $W/ui.out ]] && { echo "live driver output:"; cat "$W/ui.out"; }
ls "$S"/80x24-*.svg >/dev/null 2>&1 || { echo "no live frames"; exit 1; }
for sz in 80x24 85x12 40x30; do   # the size pictures: Ready, Recording (all three phrases), Review
  for pair in "ready:01-ready" "recording:05-recording3" "review:06-review"; do png "$sz-${pair#*:}" "live-${pair%%:*}-$sz"; done
done
# the hero GIF: every 80x24 frame, with how long it stays (ms), under 1 MB
for f in "$S"/80x24-*.svg; do b=$(basename "$f" .svg); inkscape "$f" -o "$S/$b.png" -w 720 >/dev/null 2>&1; done
"$PILPY" - "$IMG" "$S" <<'PY'
import glob, sys, os
from PIL import Image
img, tmp = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(f"{tmp}/80x24-*.png"))
hold = {"ready": 1200, "recording0": 900, "recording1": 900, "recording2": 900, "recording3": 1400, "review": 2200, "copied": 2600}
frames, durs = [], []
for f in files:
    tag = f.rsplit("-", 1)[1][:-4]
    frames.append(Image.open(f).convert("RGB")); durs.append(hold.get(tag, 900))
pal = frames[2].quantize(colors=48, method=Image.Quantize.MEDIANCUT)
frames = [fr.quantize(palette=pal, dither=Image.Dither.NONE) for fr in frames]
frames[0].save(f"{img}/live.gif", save_all=True, append_images=frames[1:], duration=durs, loop=0, optimize=True)
print("live.gif", os.path.getsize(f"{img}/live.gif"), "bytes,", len(frames), "frames")
PY

echo "== Append and Send: text landing in a stand-in Claude pane (from what the fake tmux received)"
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude' FAKE_PANE_FILE=$W/pane; rm -f "$W/pane"
mrun '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 24)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); go(2); go(3)
        for key in ("a", "e"):
            await pilot.press("enter"); await until(pilot, lambda: len(logtext(app)) == 3)
            await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.pause(0.2)
            await pilot.press(key); await until(pilot, lambda: app.phase == "ready"); await pilot.pause(0.2)
            open(f"{W}/pane.{key}", "w").write(open(f"{W}/pane").read()); open(f"{W}/pane", "w").close()
        await pilot.press("q"); await pilot.pause(0.2)
asyncio.run(main())
' > "$W/ui.out" 2>&1; cat "$W/ui.out"
paneshot() {   # paneshot NAME  (reads the pane text on stdin: "<ENTER>" at the end means it was submitted)
  local t rule; t=$(cat); rule=$(printf '─%.0s' $(seq 68))
  if [[ $t == *"<ENTER>" ]]; then
    printf '[b]>[/b] %s\n[dim]  ...Claude answers here...[/dim]\n\n%s\n[b]>[/b] [reverse] [/reverse]\n%s' "${t%<ENTER>}" "$rule" "$rule" | termshot "$1" 72 8 "tmux · claude pane"
  else
    printf '\n\n\n%s\n[b]>[/b] %s[reverse] [/reverse]\n%s' "$rule" "$t" "$rule" | termshot "$1" 72 8 "tmux · claude pane"
  fi
}
A_TXT=$(cat "$W/pane.a"); S_TXT=$(cat "$W/pane.e")
echo "append pane: $A_TXT"; echo "send pane: $S_TXT"
paneshot pane-append < "$W/pane.a" ; paneshot pane-send < "$W/pane.e"
png pane-append pane-append 720; png pane-send pane-send 720

echo "== notes: a terminal still"
dfresh; mkdir -p "$W/gate"; ND=$W/proj; rm -rf "$ND"
nstart "$ND" FAKE_PW_GATE="$W/gate" FAKE_ENGINE_TEXT="$PHRASES"; nwait 1; touch "$W/gate/go2"; nwait 2; touch "$W/gate/go3"; nwait 3; nstop
{ printf '[dim]$[/dim] stenographr notes\n'; cat "$W/notes.out"; printf '[dim]^C[/dim]\n\n[dim]$[/dim] cat steno-%s.txt\n' "$(date +%F)"
  sed -E 's/^(\[[0-9]{2}:[0-9]{2}:[0-9]{2}\])/\\\1/; s/ · audio\/.*$/ · audio\/.../' "$ND"/steno-*.txt | sed -E "s|$W|~|g; /^end: /s/.*/end: ... · ok/"; } > "$W/notes.txt"
cat "$W/notes.txt"
termshot notes 86 14 "terminal" < "$W/notes.txt"; png notes notes-session 800

echo "== recall: a terminal still"
dfresh; mkdir -p "$A/clips"; TD=$(date +%F)
printf '# 20261109_083630 · recorded 2026-11-09 08:36 · 00:00:05\nsource: x\nengine: fake (cpu)\n\n[00:00:00 → 00:00:03 | 08:36:30] Remind me to book the venue.\n' > "$A/clips/clip-2026-11-09-083630.txt"
{ printf 'start: %s 09:02:00 · live · unknown\n[09:02:01] so the plan is\nclean:\n[09:02:01] So the plan is to ship the README today.\nend: %s 09:02:30 · 30s · ok · copied\n' $TD $TD
  printf 'start: %s 10:11:00 · notes · /home/me/project\n[10:11:01] first sentence.\n[10:11:07] second sentence.\nend: %s 10:11:20 · 20s · ok\n' $TD $TD
  echo "clip: $TD 10:20:00 · 20261109_083630 → clips/clip-2026-11-09-083630.txt"; } > "$A/steno-$TD.txt"
{ printf '[dim]$[/dim] recall\n'; steno recall </dev/null 2>&1 | sed 's/\[/\\[/g'; } > "$W/recall.txt"
cat "$W/recall.txt"
termshot recall 80 9 "terminal" < "$W/recall.txt"; png recall recall 800

echo "== clip: what the README quotes"
dfresh; V=$(mkvid 20261109_083630.mp4); steno clip "$V" --out "$OUT" 2>&1 | sed "s|$W|~|g" | tee "$W/clip.out"
cat "$A"/steno-*.txt; echo ---; cat "$OUT"/*.txt
