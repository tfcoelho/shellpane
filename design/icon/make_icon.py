#!/usr/bin/env python3
"""Shellpane's icon, variant B ("Mac → server"): a light pane (your Mac), a teal pane (the server),
and a prompt chevron between them. Writes icon.svg (128 px and up), icon-small.svg (16 and 32 px:
less padding, no shadow, heavier chevron) and favicon.svg (the site)."""
import pathlib
OUT = pathlib.Path(__file__).parent

DEFS = '''<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2e2e33"/><stop offset="1" stop-color="#17171a"/></linearGradient>
  <linearGradient id="mac" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f6f6f9"/><stop offset="1" stop-color="#d9d9e0"/></linearGradient>
  <linearGradient id="server" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#16b192"/><stop offset="1" stop-color="#0b8470"/></linearGradient>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-opacity=".30"/></filter>
</defs>'''

def chevron(cx, cy, h, w, sw):
    return (f'<path d="M{cx - w/2:g} {cy - h/2:g} L{cx + w/2:g} {cy:g} L{cx - w/2:g} {cy + h/2:g}" fill="none" '
            f'stroke="#f2f2f5" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"/>')

def icon(body, pane_w, pane_h, gap, radius, chev, shadow=True):
    x0, size = body
    cx = cy = 512
    left = cx - gap / 2 - pane_w
    right = cx + gap / 2
    top = cy - pane_h / 2
    rx = size * 0.225
    shade = ' filter="url(#shadow)"' if shadow else ''
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{DEFS}'
            f'<rect x="{x0}" y="{x0}" width="{size}" height="{size}" rx="{rx:g}" fill="url(#body)"{shade}/>'
            f'<rect x="{x0 + 1.5}" y="{x0 + 1.5}" width="{size - 3}" height="{size - 3}" rx="{rx - 1.5:g}" fill="none" stroke="#fff" stroke-opacity=".12" stroke-width="3"/>'
            f'<rect x="{left:g}" y="{top:g}" width="{pane_w}" height="{pane_h}" rx="{radius}" fill="url(#mac)"/>'
            f'<rect x="{right:g}" y="{top:g}" width="{pane_w}" height="{pane_h}" rx="{radius}" fill="url(#server)"/>'
            # Optical centring: the point and round caps make the chevron look further right than it is.
            f'{chevron(cx - chev[1] * 0.08, cy, *chev)}</svg>')

# 824 body on the macOS grid; panes 220×470 with a 156 gap, ~114 from the body's edge.
(OUT / "icon.svg").write_text(icon((100, 824), 220, 470, 156, 30, (140, 70, 44)))
# Small sizes: body fills more of the canvas, shapes bigger, chevron heavier, no shadow.
(OUT / "icon-small.svg").write_text(icon((40, 944), 250, 620, 250, 40, (240, 116, 92), shadow=False))
(OUT / "favicon.svg").write_text(icon((0, 1024), 270, 680, 270, 44, (260, 124, 100), shadow=False))
print("wrote icon.svg, icon-small.svg, favicon.svg")
