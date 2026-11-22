"""Builds the logo and icons: web/favicon.svg and the PNG icons in web/icons/
for the home screen (iPhone), installed app (manifest) and older browsers,
and the Mac app's icon in mac/PianoTunah/Assets.xcassets/AppIcon.appiconset.

  docker run --rm -v "$PWD":/w -w /w python:3.12-alpine sh -c \
    "apk add -q cairo && pip install -q cairosvg pillow && python tools/icons.py"

Piano keys run diagonally and together form a rounded square; each black
key starts where its centre line meets the square's edge.
"""
import io
import json
import math
import os

import cairosvg
from PIL import Image, ImageFilter

BLUE, IVORY, EBONY, EBONY_TOP, SHADE = "#2c5a85", "#f6f3ea", "#0d1216", "#3a4655", "#b5c0ca"
ANGLE = -30  # degrees
KEY = 21  # white key width, units of 100
GAP = 2.8
KEYS = 6
BLACKS = (1, 2, 4)  # gaps with a black key: C♯ D♯ F♯
SHOWN = 36  # how far each black key reaches into the square


def inside(x, y, inset, r):
    lo, hi = inset, 100 - inset
    if not (lo <= x <= hi and lo <= y <= hi):
        return False
    cx, cy = min(max(x, lo + r), hi - r), min(max(y, lo + r), hi - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def logo(frame_rx=22, inset=15, r=15):
    """frame_rx: corner radius of the blue square (0 for full-bleed icons that
    the system rounds itself). inset, r: the square the keys fill."""
    a = math.radians(ANGLE)

    def rot(x, y):
        return (50 + (x - 50) * math.cos(a) - (y - 50) * math.sin(a), 50 + (x - 50) * math.sin(a) + (y - 50) * math.cos(a))

    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">',
        f'<defs><clipPath id="keys"><rect x="{inset}" y="{inset}" width="{100 - 2 * inset}" height="{100 - 2 * inset}" rx="{r}"/></clipPath></defs>',
        f'<rect width="100" height="100" rx="{frame_rx}" fill="{BLUE}"/>',
        f'<g clip-path="url(#keys)"><rect width="100" height="100" fill="{BLUE}"/><g transform="rotate({ANGLE} 50 50)">',
    ]
    x0 = 50 - KEYS * KEY / 2
    for i in range(KEYS):
        out.append(f'<rect x="{x0 + i * KEY + GAP / 2:.2f}" y="-40" width="{KEY - GAP:.2f}" height="180" fill="{IVORY}"/>')
    bw = KEY * 0.58
    for i in BLACKS:
        cx = x0 + i * KEY
        y = -40.0
        while y < 140 and not inside(*rot(cx, y), inset, r):
            y += 0.25
        y0, y1 = y - 20, y + SHOWN  # starts outside the square, so its edge cuts the key
        x = cx - bw / 2
        out.append(f'<rect x="{x + 2:.2f}" y="{y0:.2f}" width="{bw:.2f}" height="{y1 - y0 + 4:.2f}" fill="{SHADE}"/>')
        out.append(f'<rect x="{x:.2f}" y="{y0:.2f}" width="{bw:.2f}" height="{y1 - y0:.2f}" rx="1.5" fill="{EBONY}"/>')
        out.append(f'<rect x="{x + bw * 0.16:.2f}" y="{y0:.2f}" width="{bw * 0.68:.2f}" height="{y1 - y0 - 6:.2f}" rx="1.2" fill="{EBONY_TOP}"/>')
    out.append("</g></g></svg>")
    return "".join(out)


os.makedirs("web/icons", exist_ok=True)
rounded = logo()
with open("web/favicon.svg", "w") as f:
    f.write(rounded + "\n")
png = lambda svg, size, name: cairosvg.svg2png(bytestring=svg.encode(), write_to=f"web/icons/{name}", output_width=size, output_height=size)
png(rounded, 32, "icon-32.png")
png(rounded, 192, "icon-192.png")
png(rounded, 512, "icon-512.png")
# iOS rounds the corners itself and shows transparency as black.
png(logo(frame_rx=0), 180, "apple-touch-icon.png")
# Android crops maskable icons to a circle or other shape: the logo scaled to
# 84 % keeps the keys within the central 80 %.
inner = logo(frame_rx=0).replace('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">', '<svg x="8" y="8" width="84" height="84" viewBox="0 0 100 100">')
maskable = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="{BLUE}"/>{inner}</svg>'
png(maskable, 512, "icon-maskable-512.png")

# macOS shows the icon as it is drawn, so it follows Apple's icon grid: on a
# 1024 canvas, a squircle of 824 with continuous corners of radius 185.4,
# centred, and a soft shadow below it in the margin. The full-bleed logo
# fills the squircle, so the keys keep the web's proportions.
MAC = "mac/PianoTunah/Assets.xcassets/AppIcon.appiconset"
BODY, BODY_R = 824, 185.4
# One continuous corner, from the edge before it to the edge after it: the
# start, then three Bézier segments, in units of the radius from the corner.
CORNER = ((1.52866483, 0), (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600),
          (0.37282392, 0.16906013), (0.16906013, 0.37282392), (0.06549600, 0.66993427),
          (0, 0.86840689), (0, 1.08849323), (0, 1.52866483))


def squircle(x0, y0, side, r):
    x1, y1 = x0 + side, y0 + side
    corners = (  # top right, bottom right, bottom left, top left: clockwise
        lambda a, b: (x1 - a * r, y0 + b * r),
        lambda a, b: (x1 - b * r, y1 - a * r),
        lambda a, b: (x0 + a * r, y1 - b * r),
        lambda a, b: (x0 + b * r, y0 + a * r),
    )
    d = []
    for i, at in enumerate(corners):
        pts = [at(a, b) for a, b in CORNER]
        d.append(("M" if i == 0 else "L") + "%.2f %.2f" % pts[0])
        for j in (1, 4, 7):
            d.append("C" + " ".join("%.2f %.2f" % p for p in pts[j:j + 3]))
    return "".join(d) + "Z"


def mac_icon(size):
    m = (1024 - BODY) / 2
    body = squircle(m, m, BODY, BODY_R)
    inner = logo(frame_rx=0).replace('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">', f'<svg x="{m}" y="{m}" width="{BODY}" height="{BODY}" viewBox="0 0 100 100">')
    art = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs><clipPath id="body"><path d="{body}"/></clipPath></defs><g clip-path="url(#body)">{inner}</g></svg>'
    shadow = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><path d="{body}" transform="translate(0 10)" fill="#000" fill-opacity="0.3"/></svg>'
    render = lambda svg: Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size))).convert("RGBA")
    icon = render(shadow).filter(ImageFilter.GaussianBlur(5 * size / 1024))
    icon.alpha_composite(render(art))
    return icon


os.makedirs(MAC, exist_ok=True)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        mac_icon(points * scale).save(f"{MAC}/{name}", optimize=True)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
info = {"author": "xcode", "version": 1}
with open(f"{MAC}/Contents.json", "w") as f:
    json.dump({"images": images, "info": info}, f, indent=2)
    f.write("\n")
with open(f"{os.path.dirname(MAC)}/Contents.json", "w") as f:
    json.dump({"info": info}, f, indent=2)
    f.write("\n")
