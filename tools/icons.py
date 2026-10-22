"""Builds the logo and icons: web/favicon.svg and the PNG icons in web/icons/
for the home screen (iPhone), installed app (manifest) and older browsers.

  docker run --rm -v "$PWD":/w -w /w python:3.12-alpine sh -c \
    "apk add -q cairo && pip install -q cairosvg && python tools/icons.py"

Piano keys run diagonally and together form a rounded square; each black
key starts where its centre line meets the square's edge.
"""
import math
import os

import cairosvg

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
