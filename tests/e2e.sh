#!/usr/bin/env bash
# Lossless round-trip check: show a colour test pattern on Xvfb, serve it with x11vnc,
# grab it with rfbcheck over ZRLE, and require a bit-exact match.
# Needs: Xvfb x11vnc imagemagick python3, and `swift build --product rfbcheck` in mac/.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT

python3 - "$tmp/pattern.ppm" <<'PY'
import sys, random
w, h = 640, 480
random.seed(1)
px = bytearray()
for y in range(h):
    for x in range(w):
        if y < 160:   r, g, b = x * 255 // w, y * 255 // 160, 255 - x * 255 // w      # gradient -> raw tiles
        elif y < 320: r, g, b = [(230, 30, 90), (20, 200, 120), (40, 60, 220)][(x // 3 + y // 5) % 3]  # 3 colours -> packed palette
        elif x < 320: r, g, b = (12, 12, 18) if (x // 40) % 2 else (250, 180, 0)               # long runs -> RLE
        elif x < 480: r, g, b = random.randrange(256), random.randrange(256), random.randrange(256)  # noise -> raw tiles
        else:         r, g, b = random.choice([(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (1, 2, 3)])
        px += bytes((r, g, b))
open(sys.argv[1], "wb").write(b"P6\n%d %d\n255\n" % (w, h) + px)
PY

Xvfb :77 -screen 0 640x480x24 -nolisten tcp &
sleep 1
DISPLAY=:77 display -window root "$tmp/pattern.ppm" || true  # exits 1 after setting the root on Xvfb
x11vnc -display :77 -rfbport 5977 -localhost -nopw -nocursor -shared -forever -o "$tmp/x11vnc.log" &
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/5977) 2>/dev/null && break; sleep 0.2; done

mac/.build/debug/rfbcheck 127.0.0.1 5977 "$tmp/got.ppm"
grep -qi zrle "$tmp/x11vnc.log" || { echo "FAIL: server did not use ZRLE"; cat "$tmp/x11vnc.log"; exit 1; }
cmp "$tmp/pattern.ppm" "$tmp/got.ppm" && echo "PASS: frame is bit-exact over ZRLE"
