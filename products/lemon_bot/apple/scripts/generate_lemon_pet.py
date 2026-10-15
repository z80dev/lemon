#!/usr/bin/env python3
"""Draw Lemon Bot's original pixel pet, without external artwork or fonts.

Requires Python 3 and Pillow 12. Generate a Codex V2 package and QA previews:
    python3 generate_lemon_pet.py --output /tmp/lemon-pet-art --check
The output root contains lemon/{pet.json,spritesheet.png} and qa/ previews.
--check validates the files just generated (including every used/unused cell).
Art is drawn on a 48×52 grid, then enlarged 4× with nearest-neighbour sampling.
The fixed palette, geometry and frame sequences make output deterministic.
"""

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


ART_SIZE = (48, 52)
SCALE = 4
CELL = (192, 208)
ATLAS_SIZE = (1536, 2288)
PALETTE = {
    "outline": "#3F4A33",
    "ink": "#27301F",
    "lemon": "#E9D474",
    "shade": "#C9B04F",
    "light": "#F6EBA8",
    "leaf": "#3C6248",
    "leaf_light": "#4C8A58",
    "vein": "#8EAE69",
    "blush": "#D99A77",
    "tear": "#95BDC2",
    "screen": "#344739",
    "glass": "#BCD8BE",
    "case": "#A6B18D",
}
MANIFEST = {
    "id": "lemon",
    "displayName": "Lemon",
    "description": "Lemon Bot's own lemon buddy.",
    "spritesheetPath": "spritesheet.png",
    "spriteVersionNumber": 2,
}
ROW_NAMES = (
    "idle", "running-right", "running-left", "waving", "jumping",
    "failed", "waiting", "running", "review", "look-up-to-right",
    "look-down-to-left",
)
FRAME_COUNTS = (6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8)
# PetAnimation.contractDurations, in milliseconds. Gaze rows are static poses;
# their QA-only 150 ms sweep has no runtime animation timing contract.
DURATIONS = (
    (280, 110, 110, 140, 140, 320),
    (120, 120, 120, 120, 120, 120, 120, 220),
    (120, 120, 120, 120, 120, 120, 120, 220),
    (140, 140, 140, 280),
    (140, 140, 140, 140, 280),
    (140, 140, 140, 140, 140, 140, 140, 240),
    (150, 150, 150, 150, 150, 260),
    (120, 120, 120, 120, 120, 220),
    (150, 150, 150, 150, 150, 280),
    (150,) * 8,
    (150,) * 8,
)


class Lemon:
    """One pose; all part coordinates share the same body-local grid.

    Baseline is art pixel 48. Only intentional hops/steps lift the feet.
    Squash deforms the body around its bottom, never the entire sprite/cell.
    """

    def __init__(self, *, dy=0, lean=0, squash=0):
        self.image = Image.new("RGBA", ART_SIZE)
        self.draw = ImageDraw.Draw(self.image)
        self.dy = dy
        self.lean = lean
        self.squash = squash

    def point(self, xy):
        x, y = xy
        return (x + self.lean, y + self.dy + round((44 - y) * self.squash / 24))

    def line(self, points, color="ink", width=1):
        self.draw.line([self.point(p) for p in points], fill=PALETTE[color], width=width)

    def polygon(self, points, color, outline=None):
        self.draw.polygon([self.point(p) for p in points], fill=PALETTE[color],
                          outline=PALETTE[outline] if outline else None)

    def rect(self, box, color):
        a, b = self.point(box[:2]), self.point(box[2:])
        self.draw.rectangle((*a, *b), fill=PALETTE[color])

    def feet(self, stride=0):
        left_y = 48 - max(0, stride)
        right_y = 48 - max(0, -stride)
        for x, y, spread in ((17, left_y, -1), (29, right_y, 1)):
            self.polygon([(x, 42), (x + 3, 42), (x + 3, y - 2),
                          (x + 3 + spread, y - 1), (x + 3 + spread, y),
                          (x - 2 + spread, y), (x - 2 + spread, y - 2),
                          (x, y - 3)], "shade", "outline")
            self.line([(x, y - 1), (x + 2, y - 1)], "lemon")

    def arms(self, left="rest", right="rest", phase=0):
        # Each hand meets the body; there are no detached decorative effects.
        for side, pose in ((-1, left), (1, right)):
            def p(x, y):
                return (x if side == 1 else 48 - x, y)
            if pose == "wave":
                top = (24, 22, 24, 29)[phase % 4]
                points = [(35, 34), (38, 33), (40, top + 3), (40, top),
                          (42, top), (43, top + 2), (42, top + 5),
                          (40, 35), (37, 37)]
            elif pose == "ask":
                top = 27 - phase % 2
                points = [(35, 34), (38, 33), (39, top), (41, top - 1),
                          (42, top + 1), (41, 34), (38, 37)]
            elif pose == "up":
                points = [(35, 32), (38, 28), (40, 26), (42, 27),
                          (42, 29), (39, 32), (37, 35)]
            elif pose == "swing":
                y = 35 + phase
                points = [(35, 32), (38, 33), (40, y), (39, y + 2),
                          (37, y + 1), (35, 36)]
            else:
                points = [(35, 33), (38, 34), (40, 37), (39, 39),
                          (37, 39), (35, 36)]
            self.polygon([p(x, y) for x, y in points], "lemon", "outline")

    def body(self):
        # The uneven tips and rising top-right shoulder echo LemonBlobShape.
        contour = [(7, 33), (9, 31), (10, 28), (12, 25), (15, 22),
                   (19, 20), (24, 19), (28, 20), (31, 22), (34, 25),
                   (36, 27), (40, 29), (40, 30), (38, 32), (37, 35),
                   (35, 39), (32, 42), (28, 44), (22, 45), (17, 44),
                   (13, 42), (11, 39), (10, 36), (8, 35)]
        self.polygon(contour, "lemon", "outline")
        self.polygon([(12, 37), (15, 40), (20, 42), (26, 42), (31, 40),
                      (35, 36), (37, 32), (37, 35), (34, 40), (31, 42),
                      (27, 43), (22, 44), (17, 43), (14, 41)], "shade")
        self.polygon([(12, 29), (14, 26), (17, 23), (21, 22), (23, 22),
                      (23, 23), (18, 25), (15, 28), (14, 30)], "light")
        self.rect((12, 32, 12, 33), "light")

    def leaf(self, droop=0):
        self.line([(25, 20), (26, 17), (28, 16)], "outline", 2)
        self.polygon([(27, 17), (28, 14 + droop), (31, 12 + droop),
                      (36, 12 + droop), (35, 15 + droop),
                      (32, 18 + droop), (29, 18 + droop)], "leaf", "outline")
        self.polygon([(29, 16 + droop), (32, 13 + droop),
                      (35, 13 + droop), (32, 16 + droop)], "leaf_light")
        self.line([(28, 17), (32, 15 + droop)], "vein")

    def face(self, *, expression="happy", gaze=(0, 0)):
        gx, gy = gaze
        eyes = ((20 + gx, 31 + gy), (28 + gx, 30 + gy))
        if expression == "blink":
            for x, y in eyes:
                self.line([(x, y + 1), (x + 2, y + 1)])
        elif expression == "focus":
            for x, y in eyes:
                self.line([(x - 1, y), (x + 2, y + 1)])
                self.rect((x + 1, y + 1, x + 2, y + 2), "ink")
        elif expression == "sad":
            for x, y in eyes:
                self.line([(x - 1, y), (x + 1, y - 1), (x + 2, y - 1)])
                self.rect((x, y + 2, x + 1, y + 3), "ink")
        elif expression == "joy":
            for x, y in eyes:
                self.line([(x - 1, y + 1), (x, y), (x + 1, y), (x + 2, y + 1)])
        else:
            for index, (x, y) in enumerate(eyes):
                self.rect((x, y, x + 1, y + 1 + index), "ink")
        mx, my = 24 + gx, 36 + gy
        if expression == "sad":
            self.line([(mx - 1, my + 2), (mx, my + 1), (mx + 2, my + 1),
                       (mx + 3, my + 2)])
        elif expression == "focus":
            self.line([(mx, my + 1), (mx + 3, my + 1)])
        else:
            self.line([(mx - 1, my), (mx, my + 1), (mx + 2, my + 1),
                       (mx + 4, my - 1)])
        self.rect((17 + gx, 35 + gy, 18 + gx, 35 + gy), "blush")
        self.rect((32 + gx, 34 + gy, 33 + gx, 34 + gy), "blush")

    def laptop(self, phase):
        self.polygon([(17, 39), (34, 39), (35, 45), (33, 46),
                      (16, 46)], "case", "outline")
        self.rect((19, 40, 32, 44), "screen")
        self.line([(20, 41), (21, 42), (20, 43)], "light")
        self.line([(24, 43), (26 + phase % 3, 43)], "leaf_light")
        self.line([(15, 47), (35, 47)], "outline")
        self.line([(17, 46), (33, 46)], "light")
        # Stub hands rest on the keyboard; alternate one-pixel typing taps.
        y = 39 + phase % 2
        self.polygon([(13, 36), (16, 36), (19, y), (19, y + 2),
                      (17, y + 2), (14, 39)], "lemon", "outline")
        self.polygon([(35, 35), (37, 36), (36, 39), (33, y + 2),
                      (31, y + 2), (31, y), (34, 37)], "lemon", "outline")

    def magnifier(self, phase):
        x, y = (34, 32 + (phase in (2, 3)))
        self.line([(31, 42), (x + 1, y + 6)], "outline", 3)
        self.line([(32, 41), (x + 1, y + 6)], "shade")
        self.polygon([(x - 3, y - 4), (x + 2, y - 4), (x + 4, y - 2),
                      (x + 4, y + 2), (x + 2, y + 4), (x - 3, y + 4),
                      (x - 5, y + 2), (x - 5, y - 2)], "outline")
        self.polygon([(x - 2, y - 3), (x + 1, y - 3), (x + 3, y - 1),
                      (x + 3, y + 1), (x + 1, y + 3), (x - 2, y + 3),
                      (x - 4, y + 1), (x - 4, y - 1)], "glass")
        self.line([(x - 2, y - 2), (x, y - 2)], "light")
        self.rect((x - 3, y - 1, x - 3, y), "light")
        self.polygon([(34, 38), (36, 39), (35, 41), (32, 43),
                      (30, 42), (31, 40)], "lemon", "outline")
        # Other hand tucked under the chin.
        self.polygon([(12, 35), (15, 36), (19, 37), (20, 36),
                      (22, 37), (21, 39), (17, 40), (13, 38)], "lemon", "outline")

    def finish(self):
        return self.image.resize(CELL, Image.Resampling.NEAREST)


def base_pose(*, dy=0, lean=0, squash=0, stride=0, left="rest", right="rest", phase=0,
              expression="happy", gaze=(0, 0), droop=0):
    pet = Lemon(dy=dy, lean=lean, squash=squash)
    pet.feet(stride)
    pet.arms(left, right, phase)
    pet.body()
    pet.leaf(droop)
    pet.face(expression=expression, gaze=gaze)
    return pet


def idle_frame(index):
    pet = base_pose(squash=(0, -1, -1, 0, 0, 1)[index],
                    gaze=(0, -1) if index == 2 else (0, 0),
                    expression="blink" if index == 4 else "happy")
    return pet.finish()


def running_right_frame(index):
    pet = base_pose(dy=(0, -1, -1, 0, 0, -1, -1, 0)[index], lean=1,
                    stride=(0, 1, 2, 1, 0, -1, -2, -1)[index],
                    left="swing", right="swing", phase=(-1, 0, 1, 0, -1, 0, 1, 0)[index],
                    gaze=(2, 0))
    return pet.finish()


def running_left_frame(index):
    return ImageOps.mirror(running_right_frame(index))


def waving_frame(index):
    return base_pose(right="rest" if index == 3 else "wave", phase=index,
                     expression="joy" if index in (1, 2) else "happy").finish()


def jumping_frame(index):
    pet = base_pose(dy=(0, -4, -8, -4, 0)[index],
                    squash=(2, -1, 0, 0, 1)[index],
                    left="up" if index in (1, 2, 3) else "rest",
                    right="up" if index in (1, 2, 3) else "rest",
                    expression="joy" if index in (1, 2, 3) else "happy")
    return pet.finish()


def failed_frame(index):
    squash = (0, 1, 2, 2, 2, 2, 1, 0)[index]
    pet = base_pose(squash=squash, expression="sad", droop=min(squash, 2))
    # The tear grows and retreats while remaining attached to the cheek.
    if index in (2, 3, 4, 5):
        length = (0, 1, 2, 1)[index - 2]
        pet.polygon([(31, 34), (32, 35), (32, 35 + length),
                     (31, 36 + length), (30, 35 + length), (30, 35)],
                    "tear", "outline")
        pet.line([(31, 35), (31, 35 + length)], "light")
    return pet.finish()


def waiting_frame(index):
    return base_pose(dy=(0, 0, -1, -1, 0, 0)[index], right="ask", phase=index,
                     gaze=(0, -2), expression="blink" if index == 4 else "happy").finish()


def working_frame(index):
    pet = base_pose(squash=(0, 0, 1, 0, 0, 1)[index], expression="focus", gaze=(0, 1))
    pet.laptop(index)
    return pet.finish()


def review_frame(index):
    pet = base_pose(gaze=((0, 0), (1, 0), (1, -1), (0, -1), (-1, 0), (0, 0))[index])
    pet.magnifier(index)
    return pet.finish()


def look_frame(index):
    angle = math.radians(index * 22.5)
    dx, dy = math.sin(angle), -math.cos(angle)
    # Subtle lean, but unchanged feet/baseline and scale. Move the whole face
    # rather than adding white eyeballs to the brand's simple two-dot eyes.
    return base_pose(lean=round(dx), gaze=(round(dx * 2), round(dy * 2))).finish()


def make_rows():
    drawers = (idle_frame, running_right_frame, running_left_frame, waving_frame,
               jumping_frame, failed_frame, waiting_frame, working_frame, review_frame)
    rows = [[drawer(i) for i in range(FRAME_COUNTS[row])]
            for row, drawer in enumerate(drawers)]
    rows.extend([[look_frame(i) for i in range(8)], [look_frame(i) for i in range(8, 16)]])
    return rows


def checker(size, *, dark=False):
    colors = ("#252B28", "#303834") if dark else ("#EEEDE5", "#DBDED5")
    image = Image.new("RGBA", size, colors[0])
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], 16):
        for x in range(0, size[0], 16):
            if (x // 16 + y // 16) % 2:
                draw.rectangle((x, y, x + 15, y + 15), fill=colors[1])
    return image


def write_qa(rows, directory):
    directory.mkdir(parents=True, exist_ok=True)
    # Each row is displayed at 1.5× atlas resolution (6× original art pixels),
    # alternating light/dark cells. Labels belong only on this QA artifact.
    preview_cell = (288, 312)
    header, label_width = 36, 236
    sheet = Image.new("RGB", (label_width + 8 * preview_cell[0], 11 * (preview_cell[1] + header)), "#1C221E")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=20)
    for row, frames in enumerate(rows):
        y = row * (preview_cell[1] + header)
        draw.text((12, y + 12), f"{row:02} {ROW_NAMES[row]}", font=font, fill="#F6EBA8")
        draw.text((12, y + 42), f"{len(frames)} frames", font=font, fill="#A6B18D")
        for column in range(8):
            x = label_width + column * preview_cell[0]
            bg = checker(preview_cell, dark=column % 2 == 1)
            if column < len(frames):
                frame = frames[column].resize(preview_cell, Image.Resampling.NEAREST)
                bg.alpha_composite(frame)
            sheet.paste(bg.convert("RGB"), (x, y + header))
            text = f"{column * 22.5 + (180 if row == 10 else 0):g} deg" if row >= 9 else f"{column + 1}"
            draw.text((x + 10, y + 7), text, font=font, fill="#EEEDE5")
        # Simultaneous light and dark previews avoid GIF transparency/disposal
        # artifacts while showing the true pixel edges on both desktop tones.
        gif_frames = []
        for frame in frames:
            preview = Image.new("RGBA", (CELL[0] * 2, CELL[1]))
            for column in range(2):
                bg = checker(CELL, dark=column == 1)
                bg.alpha_composite(frame)
                preview.paste(bg, (column * CELL[0], 0))
            gif_frames.append(preview.convert("RGB"))
        gif_frames[0].save(directory / f"{row}.gif", save_all=True,
                           append_images=gif_frames[1:], duration=DURATIONS[row],
                           loop=0, disposal=2, optimize=False)
    sheet.save(directory / "contact-sheet.png")
    # True 96×104 display-size comparison, plus an enlarged representative pose
    # for assessing the face and the pixel contours without a huge sheet.
    sample_rows = (0, 3, 4, 5, 6, 7, 8)
    samples = Image.new("RGB", (7 * 192, 416), "#1C221E")
    for column, row in enumerate(sample_rows):
        frame = rows[row][2 if row == 4 else 0]
        for band in range(2):
            bg = checker(CELL, dark=band == 1)
            small = frame.resize((96, 104), Image.Resampling.NEAREST)
            bg.alpha_composite(small, (48, 52))
            samples.paste(bg.convert("RGB"), (column * 192, band * 208))
    samples.save(directory / "display-size.png")


def check_package(root):
    """Validate the serialized package, not merely the in-memory drawing."""
    manifest = json.loads((root / "lemon" / "pet.json").read_text(encoding="utf-8"))
    assert manifest == MANIFEST, "Manifest differs from the built-in Lemon contract"
    with Image.open(root / "lemon" / manifest["spritesheetPath"]) as atlas:
        assert atlas.mode == "RGBA", f"Expected RGBA, got {atlas.mode}"
        assert atlas.size == ATLAS_SIZE, f"Unexpected atlas size: {atlas.size}"
        alpha = atlas.getchannel("A")
        assert set(alpha.tobytes()) == {0, 255}, "Art must have crisp binary alpha"
        for row, count in enumerate(FRAME_COUNTS):
            for column in range(8):
                box = (column * CELL[0], row * CELL[1],
                       (column + 1) * CELL[0], (row + 1) * CELL[1])
                cell = atlas.crop(box)
                bounds = cell.getchannel("A").getbbox()
                if column < count:
                    assert bounds, f"Empty used cell {row}:{column}"
                    assert 0 < bounds[0] < bounds[2] < CELL[0], f"Clipped horizontally: {row}:{column}"
                    assert 0 < bounds[1] < bounds[3] < CELL[1], f"Clipped vertically: {row}:{column}"
                else:
                    assert not bounds, f"Nontransparent unused cell {row}:{column}"
                    assert not any(cell.tobytes()), f"Unused cell has hidden RGB: {row}:{column}"
        # GIF durations must survive serialization, including the final hold.
        for row in range(9):
            with Image.open(root / "qa" / f"{row}.gif") as preview:
                assert preview.n_frames == FRAME_COUNTS[row], f"Merged GIF frames in row {row}"
                for index, duration in enumerate(DURATIONS[row]):
                    preview.seek(index)
                    assert preview.info["duration"] == duration, f"Incorrect GIF timing: {row}:{index}"
    print(f"Validated RGBA {ATLAS_SIZE[0]}×{ATLAS_SIZE[1]}; row counts: {', '.join(map(str, FRAME_COUNTS))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Root for lemon/ and qa/ directories")
    parser.add_argument("--check", action="store_true", help="Validate the generated package and contract timings")
    args = parser.parse_args()
    package = args.output / "lemon"
    package.mkdir(parents=True, exist_ok=True)
    rows = make_rows()
    atlas = Image.new("RGBA", ATLAS_SIZE)
    for row, frames in enumerate(rows):
        for column, frame in enumerate(frames):
            atlas.paste(frame, (column * CELL[0], row * CELL[1]))
    atlas.save(package / "spritesheet.png", optimize=False, compress_level=9)
    (package / "pet.json").write_text(json.dumps(MANIFEST, indent=2) + "\n", encoding="utf-8")
    write_qa(rows, args.output / "qa")
    if args.check:
        check_package(args.output)


if __name__ == "__main__":
    main()
