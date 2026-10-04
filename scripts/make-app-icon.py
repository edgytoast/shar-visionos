#!/usr/bin/env python3
# Draws the SHAR VR visionOS app icon (needs Pillow), procedurally: no logos or box art.
#   scripts/make-app-icon.py visionos/App/Assets.xcassets/AppIcon.solidimagestack preview.png
# Three 1024x1024 layers (Back opaque, Middle and Front with alpha), the layout an
# AppIcon.solidimagestack takes. Springfield's sky and clouds at the back, the game's purple road
# running into the distance in the middle, a pink-frosted, sprinkled donut in front.
import math, random, sys, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = sys.argv[1]
preview = sys.argv[2]

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

# Back: the show's sky, deep blue above, pale at the horizon, with its puffy cartoon clouds.
back = Image.new("RGB", (S, S))
px = back.load()
for y in range(S):
    c = lerp((40, 118, 214), (150, 210, 250), y / (S - 1))
    for x in range(S):
        px[x, y] = c
clouds = Image.new("RGBA", (S, S), (0, 0, 0, 0))
cd = ImageDraw.Draw(clouds)
def cloud(cx, cy, w, rng):
    # A flat bottom and a row of overlapping puffs above it, as the show draws them.
    puffs = rng.randint(4, 6)
    for k in range(puffs):
        t = k / (puffs - 1)
        r = w * (0.16 + 0.12 * math.sin(t * math.pi)) * rng.uniform(0.9, 1.1)
        x = cx - w / 2 + w * t
        cd.ellipse([x - r, cy - r * 1.4, x + r, cy + r * 0.6], fill=(255, 255, 255, 255))
    cd.rounded_rectangle([cx - w / 2 - w * 0.08, cy - w * 0.08, cx + w / 2 + w * 0.08, cy + w * 0.12],
                         radius=w * 0.1, fill=(255, 255, 255, 255))
rng = random.Random(11)
for cx, cy, w in ((S * 0.22, S * 0.20, S * 0.34), (S * 0.74, S * 0.14, S * 0.30), (S * 0.56, S * 0.36, S * 0.26),
                  (S * 0.10, S * 0.44, S * 0.22), (S * 0.90, S * 0.42, S * 0.24)):
    cloud(cx, cy, w, rng)
shade = clouds.filter(ImageFilter.GaussianBlur(10))
shade.putalpha(shade.getchannel("A").point(lambda a: int(a * 0.25)))
back = back.convert("RGBA")
back = Image.alpha_composite(back, Image.eval(shade, lambda v: v).transform((S, S), Image.AFFINE, (1, 0, -6, 0, 1, -10)))
back = Image.alpha_composite(back, clouds.filter(ImageFilter.GaussianBlur(0.8))).convert("RGB")

# Middle: green ground and the purple road with its yellow dashes, running to the horizon.
middle = Image.new("RGBA", (S, S), (0, 0, 0, 0))
big = 2
M = Image.new("RGBA", (S * big, S * big), (0, 0, 0, 0))
md = ImageDraw.Draw(M)
def P(x, y):
    return (x * big, y * big)
horizon = S * 0.58
md.rectangle([P(0, horizon), P(S, S)], fill=(98, 176, 64, 255))
md.polygon([P(0, horizon), P(S, horizon), P(S, horizon + S * 0.03), P(0, horizon + S * 0.03)], fill=(74, 150, 52, 255))
vx = S * 0.5
road = [P(vx - S * 0.03, horizon), P(vx + S * 0.03, horizon), P(S * 0.95, S), P(S * 0.05, S)]
md.polygon(road, fill=(108, 84, 140, 255))
for side in (-1, 1):
    md.line([P(vx + side * S * 0.03, horizon), P(S * 0.5 + side * S * 0.45, S)], fill=(214, 214, 200, 255), width=6 * big)
# Dashes: shorter and thinner towards the horizon.
for k in range(7):
    t0 = (k / 7) ** 1.7
    t1 = ((k + 0.5) / 7) ** 1.7
    y0, y1 = horizon + (S - horizon) * t0, horizon + (S - horizon) * t1
    w0, w1 = 2 + 10 * t0, 2 + 10 * t1
    md.polygon([P(vx - w0, y0), P(vx + w0, y0), P(vx + w1, y1), P(vx - w1, y1)], fill=(250, 210, 40, 255))
middle = M.resize((S, S), Image.LANCZOS)

# Front: a pink-frosted donut with sprinkles, slightly tilted, with a soft shadow.
front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
F = Image.new("RGBA", (S * big, S * big), (0, 0, 0, 0))
fd = ImageDraw.Draw(F)
cx, cy = S * 0.5, S * 0.5
R, r = S * 0.30, S * 0.105
outline = (60, 36, 24, 255)
fd.ellipse([P(cx - R, cy - R), P(cx + R, cy + R)], fill=(214, 150, 78, 255), outline=outline, width=9 * big)
# Frosting: a wavy ring inside the dough's edge.
pts = []
for k in range(361):
    a = math.radians(k)
    rr = R * (0.86 + 0.035 * math.sin(a * 9) + 0.02 * math.sin(a * 23 + 1.3))
    pts.append(P(cx + rr * math.cos(a), cy + rr * math.sin(a)))
fd.polygon(pts, fill=(246, 120, 186, 255), outline=(150, 50, 110, 255))
fd.ellipse([P(cx - r * 1.45, cy - r * 1.45), P(cx + r * 1.45, cy + r * 1.45)], fill=(232, 98, 170, 255))
fd.ellipse([P(cx - r, cy - r), P(cx + r, cy + r)], fill=(0, 0, 0, 0), outline=outline, width=9 * big)
# Shine on the frosting.
fd.arc([P(cx - R * 0.72, cy - R * 0.72), P(cx + R * 0.72, cy + R * 0.72)], start=200, end=250, fill=(255, 210, 236, 255), width=14 * big)
srng = random.Random(3)
colours = [(255, 238, 60), (70, 200, 250), (120, 230, 110), (255, 255, 255), (255, 90, 70), (170, 110, 250)]
placed = 0
while placed < 46:
    a = srng.uniform(0, math.tau)
    d = srng.uniform(r * 1.65, R * 0.8)
    x, y = cx + d * math.cos(a), cy + d * math.sin(a)
    ang = srng.uniform(0, math.pi)
    l = S * 0.022
    dx, dy = l * math.cos(ang), l * math.sin(ang)
    fd.line([P(x - dx, y - dy), P(x + dx, y + dy)], fill=srng.choice(colours) + (255,), width=int(S * 0.016) * big)
    placed += 1
# Clear the hole (the sprinkles mustn't cross it), then redraw its edge.
hole = Image.new("L", (S * big, S * big), 0)
ImageDraw.Draw(hole).ellipse([P(cx - r, cy - r), P(cx + r, cy + r)], fill=255)
F.paste((0, 0, 0, 0), (0, 0), hole)
ImageDraw.Draw(F).ellipse([P(cx - r, cy - r), P(cx + r, cy + r)], outline=outline, width=9 * big)
F = F.resize((S, S), Image.LANCZOS).rotate(-14, resample=Image.BICUBIC, center=(S / 2, S / 2))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.putalpha(F.getchannel("A").point(lambda a: int(a * 0.45)))
shadow = shadow.filter(ImageFilter.GaussianBlur(16)).transform((S, S), Image.AFFINE, (1, 0, -10, 0, 1, -18))
front = Image.alpha_composite(front, shadow)
front = Image.alpha_composite(front, F)

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "Contents.json"), "w") as f:
    f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "layers" : [\n'
            '    {\n      "filename" : "Front.solidimagestacklayer"\n    },\n'
            '    {\n      "filename" : "Middle.solidimagestacklayer"\n    },\n'
            '    {\n      "filename" : "Back.solidimagestacklayer"\n    }\n  ]\n}\n')
for name, img in (("Back", back), ("Middle", middle), ("Front", front)):
    layer = os.path.join(out, f"{name}.solidimagestacklayer")
    content = os.path.join(layer, "Content.imageset")
    os.makedirs(content, exist_ok=True)
    img.save(os.path.join(content, f"{name}.png"))
    with open(os.path.join(layer, "Contents.json"), "w") as f:
        f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    with open(os.path.join(content, "Contents.json"), "w") as f:
        f.write('{\n  "images" : [\n    {\n      "filename" : "%s.png",\n      "idiom" : "vision",\n'
                '      "scale" : "2x"\n    }\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' % name)
catalog = os.path.dirname(out.rstrip("/"))
with open(os.path.join(catalog, "Contents.json"), "w") as f:
    f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')

# Preview: the stack, masked to the circle visionOS shows.
comp = Image.alpha_composite(Image.alpha_composite(back.convert("RGBA"), middle), front)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse([0, 0, S, S], fill=255)
bg = Image.new("RGBA", (S, S), (40, 40, 40, 255))
bg.paste(comp, (0, 0), mask)
bg.resize((512, 512), Image.LANCZOS).save(preview)
