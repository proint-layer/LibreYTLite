#!/usr/bin/env python3
"""Decide whether a region of a screenshot is a BLACK video surface.

No PIL/numpy on this box, so: sips crops the region and scales it to 8x8, and we decode that
tiny PNG by hand. The oracle is VARIANCE, not brightness -- a legitimately dark frame is still
not uniform, while a dead sample-buffer layer is flat black. Mean alone would flag every night
scene as a bug.

  blackcheck.py <png> [x y w h]        -> prints "BLACK"/"ok" + mean/var, exits 0 if BLACK
"""
import subprocess, sys, zlib, struct, os, tempfile

def tiny(png, box, n=8):
    d = tempfile.mkdtemp()
    crop = os.path.join(d, "c.png"); small = os.path.join(d, "s.png")
    x, y, w, h = box
    # sips crops around the CENTER, so offset the centre of our box to the centre of the image.
    subprocess.run(["sips", "-c", str(h), str(w), "--cropOffset", str(y), str(x), png,
                    "--out", crop], capture_output=True)
    subprocess.run(["sips", "-z", str(n), str(n), crop, "--out", small], capture_output=True)
    return small

def decode(path):
    raw = open(path, "rb").read()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, idat, w = 8, b"", 0
    depth = ctype = 0
    while pos < len(raw):
        ln, typ = struct.unpack(">I4s", raw[pos:pos+8])
        body = raw[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
        pos += 12 + ln
    data = zlib.decompress(idat)
    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    assert depth == 8, "unexpected bit depth %d" % depth
    stride = w * nch
    out, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        f = data[i]; i += 1
        line = bytearray(data[i:i+stride]); i += stride
        for k in range(stride):
            a = line[k-nch] if k >= nch else 0
            b = prev[k]
            c = prev[k-nch] if k >= nch else 0
            if   f == 1: line[k] = (line[k] + a) & 255
            elif f == 2: line[k] = (line[k] + b) & 255
            elif f == 3: line[k] = (line[k] + (a+b)//2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[k] = (line[k] + pr) & 255
        out.append(bytes(line)); prev = line
    return w, h, nch, out

def stats(png, box):
    w, h, nch, rows = decode(tiny(png, box))
    lum = []
    for r in rows:
        for px in range(w):
            p = r[px*nch:(px+1)*nch]
            lum.append(0.299*p[0] + 0.587*p[1] + 0.114*p[2] if nch >= 3 else p[0])
    m = sum(lum)/len(lum)
    v = sum((x-m)**2 for x in lum)/len(lum)
    return m, v

if __name__ == "__main__":
    png = sys.argv[1]
    # An absent or truncated capture must FAIL, never read as "ok". A WDA runner that dies
    # mid-hunt writes 0-byte PNGs; sips then produces nothing, every check errors, and the run
    # reports "0 BLACK" for cycles where nothing was measured at all. That is a false negative
    # dressed as a clean result -- exactly the shape that makes a harness worse than no harness.
    if not os.path.exists(png) or os.path.getsize(png) < 1024:
        print("%-28s UNUSABLE (missing/empty capture -- is WDA up?)" % os.path.basename(png))
        sys.exit(2)
    # Default band sits BELOW the PiP transport buttons and ABOVE the scrubber, so the window's
    # own chrome (a bright white scrubber, grey glyphs) can't manufacture variance. Calibrated
    # against a known-black capture (mean 1.1 / var 20) and two good ones (mean 88-106, var 1257+).
    box = tuple(int(a) for a in sys.argv[2:6]) if len(sys.argv) >= 6 else (200, 600, 800, 90)
    m, v = stats(png, box)
    # Flat + dark. Thresholds chosen against a known-black and a known-good capture.
    black = (v < 150.0 and m < 20.0)
    print("%-28s mean=%6.2f var=%9.2f  %s" % (os.path.basename(png), m, v, "BLACK" if black else "ok"))
    sys.exit(0 if black else 1)
