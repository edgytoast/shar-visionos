#!/usr/bin/env python3
# Draws the bare-hand control diagrams as SVG, procedurally: cartoon hands in the show's yellow with
# a bold black outline, palm towards you, five fingers (two controls use the little finger).
#
#   scripts/make-hand-art.py
#
# Writes each drawing twice: into the app's asset catalog (visionos/App/Assets.xcassets/Hands, kept
# as vectors) for the Controls guide, and into docs/images/hands for the README. Also both hands
# open, side by side (hands-pair), with where each fingertip is as data (hands-pair-anchors:
# {"width", "height", "anchors": {name: [x, y]}}, TrevorbiltKit's ControllerArt) for the guide's
# numbered markers.
#
# And the same drawings for every other port, into TrevorbiltKit (Resources/Hands.xcassets): the
# skin left white and the crease grey, so the kit can tint each hand by multiplying (outlines stay
# black, the crease a darker shade of the tone), with the touch spark and the motion arrows apart
# (<name>-marks, drawn over untinted), and the pair as one layer a hand (hands-pair-left,
# hands-pair-right), so each hand takes its own tone.
import json, math, os, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(HERE, "visionos/App/Assets.xcassets/Hands")
DOCS = os.path.join(HERE, "docs/images/hands")
KIT = os.path.join(HERE, "visionos/TrevorbiltKit/Sources/TrevorbiltKit/Resources/Hands.xcassets")

YELLOW, SHADE, INK = "#FED41D", "#E8B90C", "#1A1A1A"
WHITE, GREY = "#FFFFFF", "#D2D2D2"       # the kit's: tinted by multiplying, so white takes the tone
SPARK, ARROW = "#ED7014", "#2B7FD4"   # Trevorbilt orange for the touch, a calm blue for motion
LINE = 7                                 # the outline, in a 240 x 280 drawing

W, H = 240, 280
PALM = dict(cx=118, top=128, bottom=222, left=66, right=172)
# Fingers, little to index, for a right hand with its palm towards you (the thumb on the right):
# where each meets the palm, its length, width and lean (degrees from upright, + to the right).
FINGERS = {
    "little": dict(x=80, y=136, length=54, width=25, lean=-12),
    "ring":   dict(x=104, y=130, length=70, width=27, lean=-4),
    "middle": dict(x=130, y=128, length=78, width=27, lean=2),
    "index":  dict(x=156, y=132, length=70, width=27, lean=9),
}
THUMB = dict(x=168, y=196, width=29)


def capsule(x0, y0, x1, y1, width):
    """A finger: a round-ended bar from (x0, y0) to (x1, y1), as a path."""
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / length * width / 2, dx / length * width / 2
    r = width / 2
    return (f"M{x0 + nx:.1f},{y0 + ny:.1f} L{x1 + nx:.1f},{y1 + ny:.1f} "
            f"A{r:.1f},{r:.1f} 0 0 0 {x1 - nx:.1f},{y1 - ny:.1f} "
            f"L{x0 - nx:.1f},{y0 - ny:.1f} A{r:.1f},{r:.1f} 0 0 0 {x0 + nx:.1f},{y0 + ny:.1f} Z")


def tapered(x0, y0, r0, x1, y1, r1):
    """A finger or thumb that narrows from its base (x0, y0, radius r0) to its tip (radius r1)."""
    dx, dy = x1 - x0, y1 - y0
    d = math.hypot(dx, dy) or 1.0
    ux, uy = dx / d, dy / d
    # The outer tangents of the two end circles.
    s = (r0 - r1) / d
    c = math.sqrt(max(0.0, 1 - s * s))
    n1 = (ux * s - uy * c, uy * s + ux * c)
    n2 = (ux * s + uy * c, uy * s - ux * c)
    a0 = (x0 + n1[0] * r0, y0 + n1[1] * r0); a1 = (x1 + n1[0] * r1, y1 + n1[1] * r1)
    b1 = (x1 + n2[0] * r1, y1 + n2[1] * r1); b0 = (x0 + n2[0] * r0, y0 + n2[1] * r0)
    return (f"M{a0[0]:.1f},{a0[1]:.1f} L{a1[0]:.1f},{a1[1]:.1f} A{r1:.1f},{r1:.1f} 0 1 0 {b1[0]:.1f},{b1[1]:.1f} "
            f"L{b0[0]:.1f},{b0[1]:.1f} A{r0:.1f},{r0:.1f} 0 1 0 {a0[0]:.1f},{a0[1]:.1f} Z")


def tip(finger):
    f = FINGERS[finger]
    a = math.radians(f["lean"])
    return f["x"] + math.sin(a) * f["length"], f["y"] - math.cos(a) * f["length"]


def palm_path():
    # Chubby and round: a slightly wider top (the knuckles), full sides, a round heel.
    return ("M70,148 C68,132 80,124 96,124 L150,124 C166,124 176,134 176,150 "
            "C178,176 176,200 166,214 C154,230 132,234 116,234 C96,234 78,228 70,212 "
            "C63,196 66,170 70,148 Z")


def outlined(path, fill=YELLOW):
    return (f'<path d="{path}" fill="none" stroke="{INK}" stroke-width="{LINE * 2}" stroke-linejoin="round"/>'
            f'<path d="{path}" fill="{fill}"/>')


def spark(x, y, size=13):
    points = []
    for i in range(16):
        r = size if i % 2 == 0 else size * 0.42
        a = math.pi * i / 8
        points.append(f"{x + math.cos(a) * r:.1f},{y + math.sin(a) * r:.1f}")
    return (f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{size + 7}" fill="{SPARK}" opacity="0.22"/>'
            f'<polygon points="{" ".join(points)}" fill="{SPARK}" stroke="{INK}" stroke-width="2.5" stroke-linejoin="round"/>')


def arrow(x0, y0, x1, y1):
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    ux, uy = dx / length, dy / length
    hx, hy = x1 - ux * 15, y1 - uy * 15
    return (f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{hx:.1f}" y2="{hy:.1f}" stroke="{ARROW}" stroke-width="8" stroke-linecap="round"/>'
            f'<polygon points="{x1:.1f},{y1:.1f} {hx - uy * 12:.1f},{hy + ux * 12:.1f} {hx + uy * 12:.1f},{hy - ux * 12:.1f}" '
            f'fill="{ARROW}" stroke="{ARROW}" stroke-width="3" stroke-linejoin="round"/>')


def arrows(kind):
    """Moved like a stick: four ways (walk), or side to side (steer, turn)."""
    out = [arrow(96, 264, 50, 264), arrow(144, 264, 190, 264)]
    if kind == "all":
        # Beside the little finger: the side away from the thumb (these drawings are left hands).
        cx, cy = 212, 196
        out = [arrow(cx, cy - 8, cx, cy - 36), arrow(cx, cy + 8, cx, cy + 36),
               arrow(cx - 8, cy, cx - 30, cy), arrow(cx + 8, cy, cx + 30, cy)]
    return "".join(out)


# Where the thumb meets each finger it touches.
CONTACT = {"index": (146, 182), "middle": (128, 186), "ring": (112, 188), "little": (98, 192)}


def touch(pinch):
    """The spark where the thumb meets the finger."""
    x, y = CONTACT[pinch]
    return spark(x + 3, y + 1)


def hand(pinch=None, skin=YELLOW, shade=SHADE, marks=True):
    """An open hand, or the thumb touching one finger (folded down onto the palm to meet it).
    `marks`: with the spark where they touch (else drawn apart, over the tinted hand)."""
    parts = []
    # The palm's outline first, so fingers and the thumb join it without a seam; its fill last.
    parts.append(f'<path d="{palm_path()}" fill="none" stroke="{INK}" stroke-width="{LINE * 2}" stroke-linejoin="round"/>')
    for name, f in FINGERS.items():
        if name == pinch:
            continue
        x1, y1 = tip(name)
        parts.append(outlined(tapered(f["x"], f["y"] + 30, f["width"] / 2 + 1.5, x1, y1, f["width"] / 2 - 1), skin))
    if not pinch:
        # Relaxed, out to the side, from the ball of the thumb.
        parts.append(outlined(tapered(150, 200, 21, 210, 146, 13), skin))
    parts.append(f'<path d="{palm_path()}" fill="{skin}"/>')
    # A soft crease where the thumb's mound meets the palm.
    parts.append(f'<path d="M150,214 Q138,186 150,160" fill="none" stroke="{shade}" stroke-width="5" stroke-linecap="round"/>')
    if pinch:
        f = FINGERS[pinch]
        # Folded towards you over the palm, from the knuckle down to where the thumb meets it.
        contact = CONTACT[pinch]
        top = (f["x"], f["y"] + 4)
        parts.append(outlined(tapered(top[0], top[1], f["width"] / 2 + 1, contact[0], contact[1], f["width"] / 2 - 2), skin))
        # The fold: a crease across it, just below the knuckle.
        ax, ay = contact[0] - top[0], contact[1] - top[1]
        al = math.hypot(ax, ay); ux, uy = ax / al, ay / al
        cx, cy = top[0] + ux * 16, top[1] + uy * 16
        hw = f["width"] / 2 - 2
        parts.append(f'<path d="M{cx - uy * hw:.1f},{cy + ux * hw:.1f} Q{cx + ux * 5:.1f},{cy + uy * 5:.1f} {cx + uy * hw:.1f},{cy - ux * hw:.1f}" '
                     f'fill="none" stroke="{INK}" stroke-width="3.5" stroke-linecap="round"/>')
        # The thumb reaches up and across to it from the ball of the thumb.
        parts.append(outlined(tapered(160, 216, 19, contact[0] + 8, contact[1] + 6, 13), skin))
        if marks:
            parts.append(touch(pinch))
    return "".join(parts)


def fist(skin=YELLOW, shade=SHADE, marks=True):
    parts = [f'<path d="{palm_path()}" fill="none" stroke="{INK}" stroke-width="{LINE * 2}" stroke-linejoin="round"/>',
             f'<path d="{palm_path()}" fill="{skin}"/>']
    # Fingers curled into the palm: their backs as a row of rounded pads along the top.
    for i, x in enumerate((84, 108, 132, 156)):
        parts.append(outlined(capsule(x, 118 + abs(i - 1.5) * 4, x, 150 + abs(i - 1.5) * 4, 26), skin))
    # The thumb folded across them.
    parts.append(outlined(tapered(178, 196, 18, 104, 170, 13), skin))
    return "".join(parts)


def swept():
    """The motion lines beside a swinging hand."""
    return "".join(
        f'<path d="M{x},{y0} Q{x - 16},{(y0 + y1) / 2} {x},{y1}" fill="none" stroke="{ARROW}" stroke-width="7" stroke-linecap="round"/>'
        for x, y0, y1 in ((30, 96, 176), (14, 118, 158)))


def swing(skin=YELLOW, shade=SHADE, marks=True):
    return (swept() if marks else "") + hand(skin=skin, shade=shade)


def svg(body, mirror=False):
    group = f'<g transform="translate({W},0) scale(-1,1)">{body}</g>' if mirror else f"<g>{body}</g>"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            f"{group}</svg>\n")


def pinching(finger):
    return lambda **style: hand(finger, **style)


# name: (drawing, its marks alone, mirrored for the left hand, arrows)
DRAWINGS = {
    "hand-pinch-index-right": (pinching("index"), lambda: touch("index"), False, None),
    "hand-pinch-index-left": (pinching("index"), lambda: touch("index"), True, None),
    "hand-pinch-middle-right": (pinching("middle"), lambda: touch("middle"), False, None),
    "hand-pinch-middle-left": (pinching("middle"), lambda: touch("middle"), True, None),
    "hand-pinch-middle-left-move": (pinching("middle"), lambda: touch("middle"), True, "all"),
    "hand-pinch-middle-left-steer": (pinching("middle"), lambda: touch("middle"), True, "sides"),
    "hand-pinch-ring-right": (pinching("ring"), lambda: touch("ring"), False, None),
    "hand-pinch-ring-left": (pinching("ring"), lambda: touch("ring"), True, None),
    "hand-pinch-little-right-turn": (pinching("little"), lambda: touch("little"), False, "sides"),
    "hand-pinch-little-left": (pinching("little"), lambda: touch("little"), True, None),
    "hand-fist-right": (fist, lambda: "", False, None),
    "hand-swing-right": (swing, swept, False, None),
}
# Only the kit's (other ports' guides need them; SHAR's doesn't).
KIT_ONLY = {
    "hand-fist-left": (fist, lambda: "", True, None),
}


def write(name, text, docs=True, assets=ASSETS):
    if docs:
        os.makedirs(DOCS, exist_ok=True)
        with open(os.path.join(DOCS, name + ".svg"), "w") as f:
            f.write(text)
    folder = os.path.join(assets, name + ".imageset")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, name + ".svg"), "w") as f:
        f.write(text)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": name + ".svg", "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1},
                   "properties": {"preserves-vector-representation": True}}, f, indent=2)
        f.write("\n")


GAP = 20   # between the pair's hands


def pair_svg(body):
    width = W * 2 + GAP
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {H}" width="{width}" height="{H}">'
            f"{body}</svg>\n")


def left_of_pair(body):
    return f'<g transform="translate({W},0) scale(-1,1)">{body}</g>'


def right_of_pair(body):
    return f'<g transform="translate({W + GAP},0)">{body}</g>'


def anchors_data(assets):
    """Where each fingertip, the thumb and the palm are on the pair, as a data asset."""
    gap, width = GAP, W * 2 + GAP
    points = {name: tip(name) for name in FINGERS}
    points["thumb"] = (210, 146)
    points["palm"] = (118, 182)
    anchors = {}
    for name, (x, y) in points.items():
        anchors["left" + name.capitalize()] = [round(W - x, 1), round(y, 1)]
        anchors["right" + name.capitalize()] = [round(W + gap + x, 1), round(y, 1)]
    data = os.path.join(assets, "hands-pair-anchors.dataset")
    os.makedirs(data, exist_ok=True)
    with open(os.path.join(data, "hands-pair-anchors.json"), "w") as f:
        json.dump({"width": width, "height": H, "anchors": dict(sorted(anchors.items()))}, f, indent=2)
        f.write("\n")
    with open(os.path.join(data, "Contents.json"), "w") as f:
        json.dump({"data": [{"filename": "hands-pair-anchors.json", "idiom": "universal",
                             "universal-type-identifier": "public.json"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


def pair():
    """Both hands open, palms towards you: the left (mirrored) on the left, the right beside it."""
    write("hands-pair", pair_svg(left_of_pair(hand()) + right_of_pair(hand())), docs=False)
    anchors_data(ASSETS)


def catalog(folder):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


def main():
    catalog(ASSETS)
    for name, (draw, _, mirror, kind) in DRAWINGS.items():
        body = draw()
        text = svg(body, mirror)
        if kind:
            # Outside the mirrored group: arrows read the same for either hand.
            text = text.replace("</svg>", arrows(kind) + "</svg>")
        write(name, text)
    pair()
    print(f"{len(DRAWINGS) + 1} drawings in {os.path.relpath(DOCS, HERE)} and {os.path.relpath(ASSETS, HERE)}")

    # The kit's, to tint: each hand white, its marks apart.
    catalog(KIT)
    for name, (draw, marks, mirror, kind) in {**DRAWINGS, **KIT_ONLY}.items():
        write(name, svg(draw(skin=WHITE, shade=GREY, marks=False), mirror), docs=False, assets=KIT)
        text = svg(marks(), mirror)
        if kind:
            text = text.replace("</svg>", arrows(kind) + "</svg>")
        if marks() or kind:
            write(name + "-marks", text, docs=False, assets=KIT)
    write("hands-pair-left", pair_svg(left_of_pair(hand(skin=WHITE, shade=GREY))), docs=False, assets=KIT)
    write("hands-pair-right", pair_svg(right_of_pair(hand(skin=WHITE, shade=GREY))), docs=False, assets=KIT)
    anchors_data(KIT)
    print(f"{len(DRAWINGS) + len(KIT_ONLY) + 2} drawings to tint in {os.path.relpath(KIT, HERE)}")


if __name__ == "__main__":
    sys.exit(main())
