"""The phone page: one screen, plus its manifest and icons (generated here, so the package has no binary files)."""
from __future__ import annotations

import struct
import zlib
from functools import lru_cache

MANIFEST = """{"name": "Steno", "short_name": "Steno", "start_url": "/", "display": "standalone",
"background_color": "#14171c", "theme_color": "#14171c",
"icons": [{"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
          {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"}]}"""

ICONS = {"/icon-192.png": 192, "/icon-512.png": 512, "/apple-touch-icon.png": 180}


@lru_cache(maxsize=None)
def icon(n: int) -> bytes:
    """A red disc with a white microphone capsule on a dark square (square and filled, so it also works maskable)."""
    bg, red, white = (20, 23, 28), (226, 61, 61), (255, 255, 255)
    rows = bytearray()
    c = n / 2
    for y in range(n):
        rows.append(0)
        for x in range(n):
            dx, dy = x - c, y - c
            col = bg
            if dx * dx + dy * dy <= (0.34 * n) ** 2:
                col = red
                # capsule: width 0.12n each side, from -0.16n to +0.06n, round ends
                w, top, bot = 0.07 * n, -0.17 * n, 0.04 * n
                ay = min(max(dy, top + w), bot - w)
                if dx * dx + (dy - ay) ** 2 <= w * w:
                    col = white
                # stand: a thin bar under the capsule
                if abs(dx) <= 0.012 * n and 0.1 * n <= dy <= 0.2 * n:
                    col = white
                if abs(dy - 0.2 * n) <= 0.012 * n and abs(dx) <= 0.08 * n:
                    col = white
            rows += bytes(col)

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


HTML = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Steno</title>
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta name="theme-color" content="#14171c">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Steno">
<style>
:root{--bg:#f4f5f7;--fg:#14171c;--card:#fff;--mut:#6b7280;--line:#dfe2e7;--red:#d93636;--ok:#1d8a4b}
@media(prefers-color-scheme:dark){:root{--bg:#14171c;--fg:#eceef1;--card:#1e2229;--mut:#9aa1ad;--line:#2d333c;--red:#e23d3d;--ok:#4cc27f}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.4 system-ui,sans-serif;
 padding:max(12px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left))}
main{max-width:34rem;margin:0 auto}
.rec{display:flex;flex-direction:column;align-items:center;gap:.6rem;padding:1rem 0 .5rem}
#btn{width:9.5rem;height:9.5rem;border-radius:50%;border:0;background:var(--red);color:#fff;font-size:1.1rem;font-weight:600;
 box-shadow:0 4px 18px #0004;touch-action:manipulation}
#btn.on{border-radius:1.6rem;animation:pulse 1.4s infinite}
@keyframes pulse{50%{opacity:.75}}
#time{font-size:2.2rem;font-variant-numeric:tabular-nums}
#msg{min-height:1.3em;color:var(--mut);font-size:.9rem;text-align:center}
#msg.err{color:var(--red)}
input{width:100%;padding:.7rem .8rem;border-radius:.6rem;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}
h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:1.4rem 0 .4rem}
.note{background:var(--card);border:1px solid var(--line);border-radius:.7rem;padding:.6rem .8rem;margin-bottom:.5rem;min-width:0}
.meta{display:flex;gap:.5rem;flex-wrap:wrap;font-size:.8rem;color:var(--mut)}
.st-done{color:var(--ok)}.st-failed{color:var(--red)}
.text{margin-top:.3rem;overflow-wrap:anywhere;white-space:pre-wrap}
</style></head><body><main>
<section class="rec">
  <button id="btn" type="button">Record</button>
  <div id="time">0:00</div>
  <div id="msg"></div>
  <input id="title" type="text" placeholder="Title or tag (optional)" autocomplete="off" enterkeyhint="done">
</section>
<h2>Today</h2>
<div id="list"></div>
</main>
<script>
const $ = id => document.getElementById(id);
const btn = $('btn'), timeEl = $('time'), msg = $('msg'), titleEl = $('title'), listEl = $('list');
let rec = null, chunks = [], t0 = 0, tick = null, wake = null;
const pending = new Map();       // id -> {id, blob, type, title, seconds, state}; kept until the server says "saved"
let server = /*NOTES*/[];

function say(text, err){ msg.textContent = text || ''; msg.className = err ? 'err' : ''; }
const fmt = s => Math.floor(s/60) + ':' + String(Math.floor(s%60)).padStart(2,'0');
const newId = () => (crypto.randomUUID ? crypto.randomUUID() : Array.from({length:32}, () => Math.floor(Math.random()*16).toString(16)).join(''));

// ---- what has not reached the server yet survives a reload (IndexedDB)
let dbp = null;
function db(){
  if (!dbp) dbp = new Promise((res, rej) => {
    try {
      const r = indexedDB.open('steno', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('pending', {keyPath: 'id'});
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
    } catch (e) { rej(e); }
  });
  return dbp;
}
async function idb(mode, fn){
  try {
    const d = await db();
    return await new Promise((res, rej) => {
      const store = d.transaction('pending', mode).objectStore('pending'), r = fn(store);
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
    });
  } catch (e) { return null; }
}

// ---- recording
function pickType(){
  const want = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/webm', 'audio/ogg;codecs=opus'];
  return want.find(t => window.MediaRecorder && MediaRecorder.isTypeSupported(t)) || '';
}
async function start(){
  if (!navigator.mediaDevices || !window.MediaRecorder){ say('This browser cannot record. Open the page over https.', true); return; }
  let stream;
  btn.disabled = true;                                  // a second tap during the permission prompt must not start a second recorder
  try { stream = await navigator.mediaDevices.getUserMedia({audio: true}); }
  catch (e) { say('No microphone: allow it for this page and try again.', true); return; }
  finally { btn.disabled = false; }
  const type = pickType();
  rec = new MediaRecorder(stream, type ? {mimeType: type} : undefined);
  chunks = [];
  rec.ondataavailable = e => { if (e.data && e.data.size) chunks.push(e.data); };
  rec.onstop = () => finish(stream, rec.mimeType || type || 'audio/webm');
  rec.start(1000);
  t0 = Date.now();
  btn.textContent = 'Stop'; btn.classList.add('on'); say('Recording…');
  tick = setInterval(() => timeEl.textContent = fmt((Date.now() - t0)/1000), 250);
  try { wake = await navigator.wakeLock.request('screen'); } catch (e) { wake = null; }
}
function stop(){ if (rec && rec.state !== 'inactive') rec.stop(); }
async function finish(stream, type){
  stream.getTracks().forEach(t => t.stop());
  clearInterval(tick); try { wake && wake.release(); } catch (e) {}
  const seconds = (Date.now() - t0)/1000;
  btn.textContent = 'Record'; btn.classList.remove('on'); timeEl.textContent = '0:00';
  rec = null;
  if (!chunks.length){ say('Nothing was recorded.', true); return; }
  const n = {id: newId(), blob: new Blob(chunks, {type: type.split(';')[0]}), type: type.split(';')[0],
             title: titleEl.value.trim(), seconds, state: 'waiting'};
  titleEl.value = ''; chunks = [];
  pending.set(n.id, n); say('');
  await idb('readwrite', s => s.put({id: n.id, blob: n.blob, type: n.type, title: n.title, seconds: n.seconds}));
  render(); upload(n);
}
btn.onclick = () => rec ? stop() : start();

// ---- upload: retried until the server answers "saved"
async function upload(n, delay){
  if (n.busy) return;
  clearTimeout(n.timer); n.busy = true; n.state = 'uploading'; render();
  const ctl = new AbortController();                    // a dead mobile connection can hang a fetch for minutes: give up and retry
  const guard = setTimeout(() => ctl.abort(), 60000 + (n.blob.size / 1048576) * 30000);
  try {
    const r = await fetch('/api/notes', {method: 'POST', body: n.blob, signal: ctl.signal, headers: {
      'Content-Type': n.type || 'application/octet-stream', 'X-Note-Id': n.id,
      'X-Title': encodeURIComponent(n.title), 'X-Duration': String(n.seconds)}});
    if (r.ok){
      pending.delete(n.id); await idb('readwrite', s => s.delete(n.id)); n.busy = false; poll(); return;
    }
    if (r.status === 413 || r.status === 400){          // retrying cannot help; keep the recording in the page
      const j = await r.json().catch(() => ({}));
      n.state = 'rejected'; n.err = j.error || ('error ' + r.status); n.busy = false; render(); return;
    }
    throw new Error('status ' + r.status);
  } catch (e) {
    n.busy = false; n.state = 'retrying'; render();
    const d = Math.min((delay || 2000) * 2, 30000);
    n.timer = setTimeout(() => upload(n, d), d);
  } finally { clearTimeout(guard); }
}

// ---- the list
function esc(s){ return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
const LABEL = {waiting: 'waiting to upload', uploading: 'uploading…', retrying: 'no connection, retrying…'};
function render(){
  const rows = [];
  for (const n of pending.values()){
    const label = n.state === 'rejected' ? 'not uploaded: ' + esc(n.err) : LABEL[n.state] || n.state;
    rows.push(`<div class="note"><div class="meta"><span>${fmt(n.seconds)}</span><span class="${n.state==='rejected'?'st-failed':''}">${label}</span>
      ${n.title ? '<b>' + esc(n.title) + '</b>' : ''}</div></div>`);
  }
  for (const n of server.slice().reverse()){
    const st = n.status === 'done' ? '' : n.status === 'failed' ? 'transcription failed (audio is kept)' : n.status === 'working' ? 'transcribing…' : 'in the queue';
    rows.push(`<div class="note"><div class="meta"><span>${esc(n.time)}</span>${n.title && n.title !== 'unknown' ? '<b>' + esc(n.title) + '</b>' : ''}
      ${st ? '<span class="st-' + n.status + '">' + st + '</span>' : ''}</div>${n.text ? '<div class="text">' + esc(n.text) + '</div>' : ''}</div>`);
  }
  listEl.innerHTML = rows.join('') || '<div class="note meta">No phone notes yet today.</div>';
}
let polling = null;
async function poll(){
  clearTimeout(polling);
  try { const r = await fetch('/api/notes'); if (r.ok) server = await r.json(); } catch (e) {}
  render();
  const busy = server.some(n => n.status === 'queued' || n.status === 'working') || pending.size;
  polling = setTimeout(poll, busy ? 2500 : 15000);
}
window.addEventListener('beforeunload', e => { if (rec) { e.preventDefault(); e.returnValue = ''; } });
document.addEventListener('visibilitychange', () => {   // a phone throttles timers in the background: retry as soon as the page is back
  if (document.hidden) return;
  for (const n of pending.values()) if (n.state === 'retrying') upload(n);
  poll();
});
window.addEventListener('online', () => { for (const n of pending.values()) if (n.state === 'retrying') upload(n); });
render();
(async () => {
  const saved = await idb('readonly', s => s.getAll());
  for (const p of saved || []){ const n = {...p, state: 'waiting'}; pending.set(n.id, n); upload(n); }
  poll();
})();
</script></body></html>
"""
