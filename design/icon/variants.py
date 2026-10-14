#!/usr/bin/env python3
"""Shellpane icon variants: two panes and a prompt chevron. Writes one SVG per variant
and sheet.html comparing them at app-icon and favicon sizes, on light and dark."""
import pathlib
OUT = pathlib.Path(__file__).parent

# macOS icon grid: 1024 canvas, 824 body at 100, corner radius ~185.
BODY = '''<defs>
  <linearGradient id="bg{v}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2c2c30"/><stop offset="1" stop-color="#18181a"/></linearGradient>
  <filter id="sh{v}" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-opacity=".28"/></filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg{v})" filter="url(#sh{v})"/>
<rect x="101" y="101" width="822" height="822" rx="184" fill="none" stroke="#ffffff" stroke-opacity=".08" stroke-width="2"/>'''

def chevron(cx, cy, h, w, sw, color):
    return (f'<path d="M{cx - w/2} {cy - h/2} L{cx + w/2} {cy} L{cx - w/2} {cy + h/2}" fill="none" '
            f'stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"/>')

V = {}
# A: the original idea, only respaced. Narrower panes, a real gap, a bigger chevron.
V["A"] = ("Respaced", "Same two light panes, wider gap, bigger chevron",
  '<rect x="196" y="262" width="236" height="500" rx="34" fill="#ececf0"/>'
  '<rect x="592" y="262" width="236" height="500" rx="34" fill="#ececf0"/>'
  + chevron(512, 512, 150, 74, 46, "#4fd1b4"))
# B: local vs server. Left pane light (your Mac), right pane teal (the server), chevron light.
V["B"] = ("Mac → server", "Left pane light, right pane teal, light chevron between",
  '<rect x="196" y="262" width="236" height="500" rx="34" fill="#ececf0"/>'
  '<rect x="592" y="262" width="236" height="500" rx="34" fill="#0f9a80"/>'
  + chevron(512, 512, 150, 74, 46, "#ececf0"))
# C: outline to solid. Left pane an outline (source), right pane solid (destination), teal chevron.
V["C"] = ("Outline → solid", "Left pane outlined, right pane solid, teal chevron",
  '<rect x="218" y="284" width="192" height="456" rx="22" fill="none" stroke="#ececf0" stroke-width="44"/>'
  '<rect x="592" y="262" width="236" height="500" rx="34" fill="#ececf0"/>'
  + chevron(512, 512, 150, 74, 46, "#4fd1b4"))
# D: windows. Both panes light with a title strip; the right strip is teal (the server).
V["D"] = ("Title strips", "Light panes with header strips, the server's strip teal",
  '<rect x="196" y="262" width="236" height="500" rx="34" fill="#ececf0"/>'
  '<path d="M196 330 v-34 a34 34 0 0 1 34 -34 h168 a34 34 0 0 1 34 34 v34 z" fill="#8c8c94"/>'
  '<rect x="592" y="262" width="236" height="500" rx="34" fill="#ececf0"/>'
  '<path d="M592 330 v-34 a34 34 0 0 1 34 -34 h168 a34 34 0 0 1 34 34 v34 z" fill="#0f9a80"/>'
  + chevron(512, 546, 150, 74, 46, "#4fd1b4"))

def svg(v, inner):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
            f'{BODY.format(v=v)}{inner}</svg>')

cells = []
for v, (name, desc, inner) in V.items():
    s = svg(v, inner)
    (OUT / f"variant-{v}.svg").write_text(s)
    sizes = "".join(f'<div class="sz"><div style="width:{px}px;height:{px}px">{s}</div><span>{px}</span></div>'
                    for px in (64, 32, 16))
    cells.append(f'''<div class="v"><h2>{v}. {name}</h2><p>{desc}</p>
      <div class="row"><div class="big light">{s}</div><div class="big dark">{s}</div></div>
      <div class="row small light">{sizes}</div><div class="row small dark">{sizes}</div></div>''')

(OUT / "sheet.html").write_text(f'''<!doctype html><meta charset="utf-8"><title>Shellpane icon variants</title>
<style>body{{margin:0;padding:24px;background:#fff;font:15px -apple-system,sans-serif;color:#1d1d1f}}
.grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:24px}} h2{{margin:0;font-size:18px}} p{{margin:4px 0 10px;color:#66666b;font-size:13px;min-height:2.6em}}
.row{{display:flex;gap:8px;align-items:flex-end}} .big{{width:220px;height:220px;border-radius:10px;padding:4px}}
.big svg,.sz svg{{width:100%;height:100%;display:block}} .light{{background:#ececf0}} .dark{{background:#1e1e20}}
.small{{margin-top:8px;padding:10px;border-radius:10px;gap:18px}} .sz{{display:flex;flex-direction:column;align-items:center;gap:4px}}
.sz span{{font-size:11px;color:#85858b}} .big + .big{{margin-left:0}}
.v .row:first-of-type{{flex-direction:column}}</style>
<div class="grid">{"".join(cells)}</div>''')
print("wrote", ", ".join(f"variant-{v}.svg" for v in V), "and sheet.html")
