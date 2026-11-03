#!/usr/bin/env python3
"""Render the captured terminal session and two explanatory GIFs (Pillow)."""
import hashlib
import json
from pathlib import Path
import textwrap
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
OUT = HERE.parent
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
REG = ImageFont.truetype(FONT, 18)
SMALL = ImageFont.truetype(FONT, 15)
TITLE = ImageFont.truetype(FONT, 23)
BG, PANEL, FG, MUTED = '#11111b', '#1e1e2e', '#cdd6f4', '#9399b2'
GREEN, BLUE, GOLD = '#a6e3a1', '#89b4fa', '#f9e2af'

def canvas(title, subtitle, height=400):
    im = Image.new('RGB', (1200, height), BG)
    d = ImageDraw.Draw(im)
    d.text((30, 20), title, font=TITLE, fill=FG)
    d.text((30, 57), subtitle, font=SMALL, fill=MUTED)
    return im, d

def save(name, frames, durations):
    frames[0].save(OUT / name, save_all=True, append_images=frames[1:],
                   duration=durations, loop=0, optimize=True, disposal=2)
    frames[-1].save(HERE / (name.replace('.gif', '-still.png')))

def terminal():
    events = json.loads((HERE / 'sync-session.json').read_text())['events']
    panes = {'a': [], 'b': []}
    frames, durations = [], []
    def frame(active, caption, duration):
        im, d = canvas('Two folders. Both directions.', caption, 460)
        for side, x, label in [('a', 20, 'Alice'), ('b', 610, 'Bob')]:
            d.rounded_rectangle((x, 95, x+570, 433), radius=12, fill=PANEL,
                                outline=GREEN if active == side else '#313244', width=2)
            d.text((x+20, 110), label + '  ~/notes', font=REG, fill=BLUE)
            y = 150
            for line, color in panes[side][-13:]:
                d.text((x+18, y), line, font=SMALL, fill=color)
                y += 20
        frames.append(im)
        durations.append(duration)
    frame('a', 'Pre-paired demo friends / real croc relay / waits shortened', 1400)
    for event in events:
        side, command = event['side'], event['command']
        label = 'Alice' if side == 'a' else 'Bob'
        caption = f'{label} runs a command' if command.startswith('share') else (
            f'{label} reads the synced file' if command.startswith('cat') else f'{label} edits an ordinary file')
        old = list(panes[side])
        # Animate actual recorded commands; never fabricate CLI output.
        for n in range(4, len(command)+4, 4):
            panes[side] = old + [(line, GREEN) for line in textwrap.wrap('$ ' + command[:n], 58, subsequent_indent='  ')]
            frame(side, caption, 65)
        for line in event['output'].splitlines():
            panes[side] += [(part, FG) for part in textwrap.wrap(line, 58)]
        frame(side, caption, 2300)
    frame('a', 'Verified: both files contain both messages.', 4500)
    save('sync.gif', frames, durations)

def box(d, x, title, lines, color=BLUE):
    d.rounded_rectangle((x, 115, x+330, 300), radius=14, fill=PANEL, outline=color, width=2)
    d.text((x+22, 134), title, font=REG, fill=color)
    for i, line in enumerate(lines):
        d.text((x+22, 180+28*i), line, font=SMALL, fill=FG)

def arrow(d, direction, label):
    left, right, y = 420, 780, 215
    d.line((left, y, right, y), fill=GREEN, width=3)
    end, back = (right, right-12) if direction == 'right' else (left, left+12)
    d.polygon([(end, y), (back, y-7), (back, y+7)], fill=GREEN)
    d.text((440, 176), label, font=SMALL, fill=GREEN)

def flow():
    frames = []
    stages = [
        ('1 / Edit locally', ['plan.txt', 'Tea at 4?'], ['Waiting for changes'], None),
        ('2 / Exchange through croc', ['plan.txt', 'Tea at 4?'], ['plan.txt', 'Tea at 4?'], 'right'),
        ('3 / Edit on the other side', ['plan.txt', 'Tea at 4?'], ['plan.txt', 'Tea at 4?', 'See you at 4!'], None),
        ('4 / Exchange back', ['plan.txt', 'Tea at 4?', 'See you at 4!'], ['plan.txt', 'Tea at 4?', 'See you at 4!'], 'left'),
    ]
    for title, a, b, direction in stages:
        im, d = canvas(title, 'Conceptual view / ordinary files on both machines')
        box(d, 30, 'Alice', a)
        box(d, 840, 'Bob', b)
        if direction:
            arrow(d, direction, 'changes via croc')
        d.text((30, 340), 'Offline? Local edits wait for the next exchange.', font=REG, fill=MUTED)
        frames.append(im)
    save('sync-flow.gif', frames, [2200, 2600, 2200, 3500])

def conflict():
    frames = []
    # Concrete contents with a genuine hash-derived winner and conflict name.
    values = ['Tea at 4?\n', 'Tea at 5?\n']
    ranked = sorted((hashlib.sha256(s.encode()).hexdigest(), s.strip()) for s in values)
    filename = f'plan.conflict-{ranked[0][0][:8]}.txt'
    stages = [
        ('1 / Start with the same file', ['plan.txt: Tea?'], ['plan.txt: Tea?'], 'Both machines have seen the same version.'),
        ('2 / Edit independently', ['plan.txt: Tea at 4?'], ['plan.txt: Tea at 5?'], 'Overlapping edits: neither version has seen the other.'),
        ('3 / Exchange versions', ['Tea at 4?', 'Tea at 5?'], ['Tea at 4?', 'Tea at 5?'], 'Keep both versions. Choose the same original by content hash.'),
        ('4 / Same result on both sides', ['plan.txt: '+ranked[1][1], filename, ranked[0][1]], ['plan.txt: '+ranked[1][1], filename, ranked[0][1]], 'Edit the original after seeing the conflict to supersede these versions.'),
    ]
    for title, a, b, footer in stages:
        im, d = canvas(title, 'Conceptual view / an overlapping text edit that cannot cleanly merge')
        box(d, 30, 'Alice', a, GOLD)
        box(d, 840, 'Bob', b, GOLD)
        if title.startswith('3'):
            arrow(d, 'right', 'both versions')
        d.text((30, 340), footer, font=SMALL, fill=MUTED)
        frames.append(im)
    save('sync-conflict.gif', frames, [2000, 2600, 2600, 5000])

terminal()
flow()
conflict()
print('Rendered sync.gif, sync-flow.gif, sync-conflict.gif and static final frames')
