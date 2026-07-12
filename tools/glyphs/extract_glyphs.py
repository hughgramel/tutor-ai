#!/usr/bin/env python3
"""Extract a hand-writing glyph library for InkTutor from the MathWriting
dataset (Google, CC BY-NC-SA 4.0) and emit ios/InkTutor/Glyphs.generated.swift.

Data source: https://storage.googleapis.com/mathwriting_data/mathwriting-2024-excerpt.tgz
(the official ~1.5MB excerpt linked from the MathWriting GitHub/paper page;
the full archive is 2.9GB and is intentionally NOT used here).

The excerpt ships two useful pools of real human ink:
  - `symbols/*.inkml`   — 100 pre-isolated single-glyph inks (label + strokes).
  - `train/*.inkml`     — 100 full handwritten expressions, each with strokes
                           we can pick out individually using `symbols.jsonl`
                           (sourceSampleId + strokeIndices -> label), the same
                           file the full dataset uses to build its `symbols/`
                           and `synthetic/` splits.

Because the excerpt is a small sample, not every symbol InkTutor needs shows
up in it (no isolated 4, 6, 7, 8, x, y, or "-" anywhere in the 100+100
files). Downloading the full 2.9GB archive to chase a handful of missing
symbols was explicitly out of scope, so those are HAND_AUTHORED below as
literal parametric point arrays (arcs/lines), run through the exact same
resample + normalize pipeline as the real ink so they're indistinguishable
in the generated file's shape.

Usage: python3 extract_glyphs.py
Outputs:
  - ../../ios/InkTutor/Glyphs.generated.swift
  - proof.png (grid of every glyph at ~64px, for human eyeballing)
"""
import json
import math
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
EXCERPT = HERE / "mathwriting-2024-excerpt"
IOS_OUT = HERE.parent.parent / "ios" / "InkTutor" / "Glyphs.generated.swift"
PROOF_OUT = HERE / "proof.png"

MAX_POINTS_PER_STROKE = 32

# ---------------------------------------------------------------------------
# Manual pick list: which real ink to use for each symbol.
#   ("symbols", filename)                      -> whole file, all strokes
#   ("train", sampleId, [strokeIndices])       -> just those trace ids
# Picked by: fewest strokes / cleanest shape, eyeballed via proof.png.
# ---------------------------------------------------------------------------
DATASET_PICKS = {
    "0": ("train", "050eb35c2f18a695", [16]),
    "1": ("train", "0050464363a7d02d", [6]),
    "2": ("symbols", "010b76fd723a3af2.inkml", None),
    "3": ("symbols", "013433c6b018d0e2.inkml", None),
    "+": ("train", "050eb35c2f18a695", [4, 5]),
    "=": ("train", "0050464363a7d02d", [1, 2]),
    "/": ("train", "049d2cf3f10ac2d7", [17]),
    "(": ("symbols", "012994d2a88b84a4.inkml", None),
    ")": ("symbols", "02c3a6a126b713c4.inkml", None),
    "±": ("train", "03d92e3e170bb629", [0, 1, 2]),  # plus-minus
}
# Rejected after eyeballing proof.png (see report): the excerpt's only "5"
# candidates (train 0050464363a7d02d strokes [13,14]/[9,10]) are a fast
# cursive spiral that doesn't read as "5"; its only "9" candidates (symbols
# 033e4a3693b95cf3, train 04f65fb089280e4c stroke 17) both trail into a long
# tail that reads as lowercase "g"; "." candidates are 2-point strokes that
# the unit-box normalize stretches into a diagonal line, not a dot; "√"
# candidates all have a real checkmark notch, but its natural aspect ratio is
# very wide/flat (bbox ~168x74), so after square-unit normalize the notch is
# too small to read at a typical glyph size. All four hand-authored instead.

# Symbols with no isolated exemplar in the 1.5MB excerpt (or whose only
# exemplars were rejected above): hand-authored as parametric point arrays in
# a 0-100 (x-right, y-down) design box, then fed through the same
# resample/normalize pipeline as real ink below.
HAND_AUTHORED_SYMBOLS = {"4", "5", "6", "7", "8", "9", "x", "y", "-", ".", "√", "fracbar"}


def line(p0, p1, n=12):
    x0, y0 = p0
    x1, y1 = p1
    return [(x0 + (x1 - x0) * i / (n - 1), y0 + (y1 - y0) * i / (n - 1)) for i in range(n)]


def arc(cx, cy, rx, ry, deg0, deg1, n=16):
    pts = []
    for i in range(n):
        t = deg0 + (deg1 - deg0) * i / (n - 1)
        r = math.radians(t)
        pts.append((cx + rx * math.cos(r), cy + ry * math.sin(r)))
    return pts


def hand_authored_strokes(symbol):
    if symbol == "4":
        return [
            line((58, 6), (14, 66)) + line((14, 66), (82, 66))[1:],
            line((63, 2), (63, 96)),
        ]
    if symbol == "5":
        # top flag (horizontal + short vertical down the left) then a
        # bottom curve (open "C", like the bottom of a 3 mirrored).
        flag = line((78, 8), (14, 8)) + line((14, 8), (14, 42))[1:]
        curve = arc(38, 65, 26, 24, 210, -70, n=18)
        return [flag, curve]
    if symbol == "6":
        # hook down the left side into a loop at the bottom.
        hook = arc(58, 30, 26, 26, 250, 165, n=14)
        loop = arc(42, 68, 24, 22, -20, 340, n=20)
        return [hook + loop]
    if symbol == "7":
        return [line((8, 8), (86, 8)) + line((86, 8), (34, 96))[1:]]
    if symbol == "8":
        return [
            arc(42, 29, 19, 18, 90, 450, n=18),
            arc(42, 69, 25, 24, 90, 450, n=20),
        ]
    if symbol == "9":
        # loop at top, short straight-ish tail down the right (kept short
        # so it doesn't read as a lowercase "g").
        loop = arc(46, 32, 24, 22, 70, 430, n=18)
        tail = line((68, 30), (58, 90))
        return [loop, tail]
    if symbol == ".":
        # Every glyph gets normalized to fill a unit box regardless of its
        # own natural size (scale = 1 / max(w, h) of ITS bbox), so a period
        # can't be represented as "a small mark" via size alone — whatever
        # shape traces out has to still read as a dot once stretched to
        # fill the cell. A tight closed loop (like tracing a tiny "o")
        # reads as a dot at real (small) placement size in the app, and as
        # a small ring here in the proof sheet — GlyphStore callers are
        # expected to give "." a much smaller placement box than a digit.
        return [arc(50, 50, 6, 6, 0, 360, n=10)]
    if symbol == "√":
        # real dataset exemplars have a genuine checkmark notch, but its
        # natural aspect (very wide/flat) makes the notch vanish once
        # normalized into a square unit box; author explicitly instead.
        tick = line((2, 62), (14, 78))
        rise = line((14, 78), (34, 20))
        bar = line((34, 20), (96, 20))
        return [tick + rise[1:] + bar[1:]]
    if symbol == "x":
        return [line((10, 8), (85, 92)), line((85, 8), (10, 92))]
    if symbol == "y":
        return [
            line((8, 8), (46, 55)),
            line((84, 8), (46, 55)) + line((46, 55), (34, 98))[1:],
        ]
    if symbol == "-":
        return [line((8, 50), (86, 50), n=6)]
    if symbol == "fracbar":
        return [line((4, 50), (96, 50), n=8)]
    raise KeyError(symbol)


# ---------------------------------------------------------------------------
# InkML parsing
# ---------------------------------------------------------------------------
TRACE_RE = re.compile(r'<trace id="(\d+)"[^>]*>(.*?)</trace>', re.S)


def parse_inkml_traces(path):
    """Returns {trace_id(int): [(x, y), ...]} in file order."""
    text = path.read_text(encoding="utf-8")
    traces = {}
    for m in TRACE_RE.finditer(text):
        tid = int(m.group(1))
        pts = []
        for point_str in m.group(2).strip().split(","):
            parts = point_str.split()
            x, y = float(parts[0]), float(parts[1])
            pts.append((x, y))
        traces[tid] = pts
    return traces


def load_dataset_strokes(pick):
    source, ident, stroke_indices = pick
    if source == "symbols":
        path = EXCERPT / "symbols" / ident
        traces = parse_inkml_traces(path)
        return [traces[k] for k in sorted(traces.keys())]
    elif source == "train":
        path = EXCERPT / "train" / f"{ident}.inkml"
        traces = parse_inkml_traces(path)
        return [traces[i] for i in stroke_indices]
    raise ValueError(source)


# ---------------------------------------------------------------------------
# Resample: RDP simplify, then uniform arclength cap at MAX_POINTS_PER_STROKE.
# ---------------------------------------------------------------------------
def _perp_dist(pt, a, b):
    (x, y), (ax, ay), (bx, by) = pt, a, b
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(x - ax, y - ay)
    t = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)
    px, py = ax + t * dx, ay + t * dy
    return math.hypot(x - px, y - py)


def rdp(points, epsilon):
    if len(points) < 3:
        return points[:]
    a, b = points[0], points[-1]
    dmax, idx = 0.0, 0
    for i in range(1, len(points) - 1):
        d = _perp_dist(points[i], a, b)
        if d > dmax:
            dmax, idx = d, i
    if dmax > epsilon:
        left = rdp(points[: idx + 1], epsilon)
        right = rdp(points[idx:], epsilon)
        return left[:-1] + right
    return [a, b]


def path_length(points):
    return sum(math.hypot(points[i + 1][0] - points[i][0], points[i + 1][1] - points[i][1]) for i in range(len(points) - 1))


def resample_uniform(points, n):
    if len(points) <= 1:
        return points[:]
    total = path_length(points)
    if total == 0:
        return [points[0]] * n
    step = total / (n - 1)
    out = [points[0]]
    acc = 0.0
    seg_i = 0
    d_walked = 0.0
    target = step
    while len(out) < n - 1:
        if seg_i >= len(points) - 1:
            break
        ax, ay = points[seg_i]
        bx, by = points[seg_i + 1]
        seg_len = math.hypot(bx - ax, by - ay)
        if d_walked + seg_len >= target:
            remain = target - d_walked
            t = remain / seg_len if seg_len > 0 else 0
            out.append((ax + (bx - ax) * t, ay + (by - ay) * t))
            target += step
        else:
            d_walked += seg_len
            seg_i += 1
    out.append(points[-1])
    return out[:n]


def process_stroke(points):
    if len(points) < 2:
        return points[:]
    bbox_diag = math.hypot(
        max(p[0] for p in points) - min(p[0] for p in points),
        max(p[1] for p in points) - min(p[1] for p in points),
    )
    epsilon = max(bbox_diag * 0.01, 0.5)
    simplified = rdp(points, epsilon)
    if len(simplified) > MAX_POINTS_PER_STROKE:
        simplified = resample_uniform(simplified, MAX_POINTS_PER_STROKE)
    return simplified


def normalize_glyph(strokes):
    """Scale+translate so the glyph's bbox fits a unit box, larger dimension
    == 1.0, aspect preserved, min corner at (0, 0)."""
    all_pts = [p for s in strokes for p in s]
    minx = min(p[0] for p in all_pts)
    miny = min(p[1] for p in all_pts)
    maxx = max(p[0] for p in all_pts)
    maxy = max(p[1] for p in all_pts)
    w, h = maxx - minx, maxy - miny
    scale = 1.0 / max(w, h, 1e-6)
    return [[((x - minx) * scale, (y - miny) * scale) for (x, y) in s] for s in strokes]


# ---------------------------------------------------------------------------
# Build the glyph table
# ---------------------------------------------------------------------------
def build_glyphs():
    glyphs = {}
    sources = {}
    for symbol, pick in DATASET_PICKS.items():
        raw_strokes = load_dataset_strokes(pick)
        processed = [process_stroke(s) for s in raw_strokes]
        glyphs[symbol] = normalize_glyph(processed)
        sources[symbol] = f"dataset:{pick[0]}:{pick[1]}" + (f":{pick[2]}" if pick[2] else "")
    for symbol in HAND_AUTHORED_SYMBOLS:
        raw_strokes = hand_authored_strokes(symbol)
        processed = [process_stroke(s) for s in raw_strokes]
        glyphs[symbol] = normalize_glyph(processed)
        sources[symbol] = "hand-authored"
    return glyphs, sources


SWIFT_KEY_NAMES = {
    "√": "sqrt",
    "±": "plusminus",
}


def swift_literal_key(symbol):
    # Emitted Swift dictionary key is the symbol itself; this is only used
    # in comments for readability.
    return SWIFT_KEY_NAMES.get(symbol, symbol)


def emit_swift(glyphs, sources, path):
    order = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
             "x", "y", "+", "-", "=", "(", ")", ".", "/",
             "±", "√", "fracbar"]
    lines = []
    lines.append("// Glyphs.generated.swift")
    lines.append("// GENERATED by tools/glyphs/extract_glyphs.py — do not hand-edit.")
    lines.append("//")
    lines.append("// Real human pen-stroke exemplars from the MathWriting dataset")
    lines.append("// (Google Research), CC BY-NC-SA 4.0 license:")
    lines.append("// https://creativecommons.org/licenses/by-nc-sa/4.0/")
    lines.append("// Source: https://storage.googleapis.com/mathwriting_data/mathwriting-2024-excerpt.tgz")
    lines.append("// Fine for this demo; flag for any product future (NC clause).")
    lines.append("//")
    lines.append("// Per-symbol source (dataset exemplar vs hand-authored fallback for")
    lines.append("// symbols absent from the ~1.5MB excerpt sample):")
    for sym in order:
        lines.append(f"//   {swift_literal_key(sym):<10} {sources[sym]}")
    lines.append("//")
    lines.append("// Each stroke is <=32 points, resampled (RDP simplify + uniform")
    lines.append("// arclength), normalized into a unit box (larger dimension == 1.0,")
    lines.append("// aspect preserved, origin at the glyph's top-left corner).")
    lines.append("")
    lines.append("import CoreGraphics")
    lines.append("")
    lines.append("let glyphStrokes: [String: [[CGPoint]]] = [")
    for sym in order:
        strokes = glyphs[sym]
        lines.append(f'    "{sym}": [')
        for stroke in strokes:
            pts = ", ".join(f"CGPoint(x: {x:.4f}, y: {y:.4f})" for x, y in stroke)
            lines.append(f"        [{pts}],")
        lines.append("    ],")
    lines.append("]")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_proof_png(glyphs, path):
    from PIL import Image, ImageDraw, ImageFont

    order = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
             "x", "y", "+", "-", "=", "(", ")", ".", "/",
             "±", "√", "fracbar"]
    cell = 90
    cols = 6
    rows = math.ceil(len(order) / cols)
    img = Image.new("RGB", (cols * cell, rows * cell), "white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 12)
    except Exception:
        font = ImageFont.load_default()

    glyph_px = 64
    pad = (cell - glyph_px) / 2
    for i, sym in enumerate(order):
        col, row = i % cols, i // cols
        ox, oy = col * cell + pad, row * cell + pad - 6
        draw.rectangle([col * cell, row * cell, (col + 1) * cell - 1, (row + 1) * cell - 1], outline="#dddddd")
        for stroke in glyphs[sym]:
            pts = [(ox + x * glyph_px, oy + y * glyph_px) for x, y in stroke]
            if len(pts) >= 2:
                draw.line(pts, fill="black", width=2, joint="curve")
            elif len(pts) == 1:
                draw.ellipse([pts[0][0] - 1, pts[0][1] - 1, pts[0][0] + 1, pts[0][1] + 1], fill="black")
        label = swift_literal_key(sym)
        draw.text((col * cell + 4, row * cell + cell - 14), label, fill="#888888", font=font)
    img.save(path)


def main():
    glyphs, sources = build_glyphs()
    IOS_OUT.parent.mkdir(parents=True, exist_ok=True)
    emit_swift(glyphs, sources, IOS_OUT)
    print(f"wrote {IOS_OUT}")
    emit_proof_png(glyphs, PROOF_OUT)
    print(f"wrote {PROOF_OUT}")
    n_dataset = sum(1 for s in sources.values() if s.startswith("dataset"))
    n_hand = sum(1 for s in sources.values() if s == "hand-authored")
    print(f"{len(glyphs)} glyphs: {n_dataset} from dataset, {n_hand} hand-authored")


if __name__ == "__main__":
    main()
