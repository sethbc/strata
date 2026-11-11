#!/usr/bin/env python3
"""Draw the page renders as PNGs, run on demand (never part of the suite).

From the repo root, after `lua test/render_pages.lua <dir>` wrote the JSON
dumps:

    python3 test/render_pages.py <dir> [--font <path to a .ttf>] [--scale 4]

Each <page>-<state>.json in <dir> becomes <page>-<state>.png beside it: the
128x64 screen, black, with each text at its level and each rect and line
at the level it was stroked or filled with (0-15 as grays; a path never
stroked or filled is not drawn, as on norns), scaled 4x without smoothing. Texts are drawn at their baseline in
the font given with --font at 8 px (norns' screen font, 04B_03, is
~/src/norns/resources/norns.ttf in a norns checkout); without --font, that
file when it exists, else Pillow's built-in font. Needs Pillow
(`pip install pillow`).
"""
import argparse
import glob
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 128, 64
NORNS_FONT = os.path.expanduser("~/src/norns/resources/norns.ttf")
FONT_SIZE = 8


def gray(level):
    level = max(0, min(15, int(level or 0)))
    return level * 17


def load_font(path):
    if path:
        return ImageFont.truetype(path, FONT_SIZE)
    if os.path.exists(NORNS_FONT):
        return ImageFont.truetype(NORNS_FONT, FONT_SIZE)
    return ImageFont.load_default()


def draw_state(state, font):
    image = Image.new("L", (state.get("width", WIDTH), state.get("height", HEIGHT)), 0)
    draw = ImageDraw.Draw(image)
    draw.fontmode = "1"  # no antialiasing, like the OLED's pixels
    # norns' cairo: a filled rect covers x .. x + w - 1; an outline is the
    # same box's edge. A path is painted only by screen.stroke() or
    # screen.fill(), at the level in force then (the stub records that level,
    # #474), so a path never stroked or filled ("filled" null) is not drawn
    for rect in state.get("rects", []):
        if rect.get("filled") is None:
            continue
        box = [rect["x"], rect["y"], rect["x"] + rect["w"] - 1, rect["y"] + rect["h"] - 1]
        if rect["filled"]:
            draw.rectangle(box, fill=gray(rect["level"]))
        else:
            draw.rectangle(box, outline=gray(rect["level"]))
    for line in state.get("lines", []):
        if line.get("filled") is None:
            continue
        draw.line([line["x1"], line["y1"], line["x2"], line["y2"]], fill=gray(line["level"]))
    anchors = {"left": "ls", "right": "rs", "center": "ms"}
    truetype = isinstance(font, ImageFont.FreeTypeFont)
    for text in state.get("texts", []):
        position = (text["x"], text["y"])
        if truetype:
            draw.text(position, text["text"], fill=gray(text["level"]), font=font,
                      anchor=anchors.get(text.get("align"), "ls"))
        else:
            # the built-in bitmap font has no anchors: place its top-left
            width = draw.textlength(text["text"], font=font)
            x = text["x"] - (width if text.get("align") == "right" else
                             width / 2 if text.get("align") == "center" else 0)
            draw.text((x, text["y"] - FONT_SIZE), text["text"], fill=gray(text["level"]), font=font)
    return image


def main():
    parser = argparse.ArgumentParser(description="Draw Strata's page renders as PNGs")
    parser.add_argument("directory", help="the folder test/render_pages.lua wrote")
    parser.add_argument("--font", help="a .ttf for the texts (default: norns.ttf if found, else Pillow's)")
    parser.add_argument("--scale", type=int, default=4, help="pixel scale (default 4)")
    args = parser.parse_args()
    font = load_font(args.font)
    paths = sorted(glob.glob(os.path.join(args.directory, "*.json")))
    if not paths:
        print("no .json files in " + args.directory, file=sys.stderr)
        return 1
    for path in paths:
        with open(path) as handle:
            state = json.load(handle)
        image = draw_state(state, font)
        image = image.resize((image.width * args.scale, image.height * args.scale), Image.NEAREST)
        image.save(os.path.splitext(path)[0] + ".png")
    print("%d renders written to %s" % (len(paths), args.directory))
    return 0


if __name__ == "__main__":
    sys.exit(main())
