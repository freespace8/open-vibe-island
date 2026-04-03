#!/usr/bin/env python3

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


REPO_ROOT = Path(__file__).resolve().parents[1]
BRAND_ROOT = REPO_ROOT / "Assets" / "Brand"
APP_ICONSET_DIR = BRAND_ROOT / "AppIcon.appiconset"
ICONSET_DIR = BRAND_ROOT / "OpenIsland.iconset"
INTERNAL_COLOR_DIR = BRAND_ROOT / "Internal" / "color"
INTERNAL_TEMPLATE_DIR = BRAND_ROOT / "Internal" / "template"
INTERNAL_BADGE_DIR = BRAND_ROOT / "Internal" / "badge"
ICNS_PATH = BRAND_ROOT / "OpenIsland.icns"
SVG_MASTER_PATH = BRAND_ROOT / "scout-app-icon-master.svg"

SCOUT_PATTERN = [
    "..B..B..",
    "..BBBB..",
    ".BHHHHB.",
    "BBHEHEBB",
    ".BHHHHB.",
    "..BBBB..",
    ".B....B.",
    "........",
]

APP_ICON_SPECS = [
    ("icon_16x16.png", "16x16", "1x", 16),
    ("icon_16x16@2x.png", "16x16", "2x", 32),
    ("icon_32x32.png", "32x32", "1x", 32),
    ("icon_32x32@2x.png", "32x32", "2x", 64),
    ("icon_128x128.png", "128x128", "1x", 128),
    ("icon_128x128@2x.png", "128x128", "2x", 256),
    ("icon_256x256.png", "256x256", "1x", 256),
    ("icon_256x256@2x.png", "256x256", "2x", 512),
    ("icon_512x512.png", "512x512", "1x", 512),
    ("icon_512x512@2x.png", "512x512", "2x", 1024),
]


def main() -> None:
    ensure_clean_dir(APP_ICONSET_DIR)
    ensure_clean_dir(ICONSET_DIR)
    ensure_clean_dir(INTERNAL_COLOR_DIR)
    ensure_clean_dir(INTERNAL_TEMPLATE_DIR)
    ensure_clean_dir(INTERNAL_BADGE_DIR)
    BRAND_ROOT.mkdir(parents=True, exist_ok=True)

    write_svg_master(SVG_MASTER_PATH)
    write_app_icons()
    write_internal_assets()
    write_appiconset_contents_json(APP_ICONSET_DIR / "Contents.json")
    build_icns()


def ensure_clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    hex_color = hex_color.lstrip("#")
    return tuple(int(hex_color[index : index + 2], 16) for index in range(0, 6, 2)) + (alpha,)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def solid_layer(size: tuple[int, int], color: tuple[int, int, int, int]) -> Image.Image:
    return Image.new("RGBA", size, color)


def vertical_gradient(size: tuple[int, int], top: str, bottom: str) -> Image.Image:
    top_rgba = rgba(top)
    bottom_rgba = rgba(bottom)
    image = Image.new("RGBA", size)
    pixels = image.load()
    height = max(size[1] - 1, 1)
    for y in range(size[1]):
        mix = y / height
        color = tuple(
            round(top_rgba[index] + (bottom_rgba[index] - top_rgba[index]) * mix)
            for index in range(4)
        )
        for x in range(size[0]):
            pixels[x, y] = color
    return image


def draw_shadow(base: Image.Image, box: tuple[int, int, int, int], radius: int, color: str, blur: float) -> None:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(box, radius=radius, fill=rgba(color))
    shadow = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(shadow)


def draw_glow_ellipse(base: Image.Image, box: tuple[int, int, int, int], color: str, blur: float) -> None:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse(box, fill=rgba(color))
    glow = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(glow)


def paste_masked(base: Image.Image, overlay: Image.Image, xy: tuple[int, int], mask: Image.Image) -> None:
    base.paste(overlay, xy, mask)


def draw_app_shell(size: int) -> tuple[Image.Image, tuple[int, int, int, int]]:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    icon_size = int(size * 0.86)
    icon_x = (size - icon_size) // 2
    icon_y = (size - icon_size) // 2 - max(2, size // 64)
    outer_radius = max(12, int(icon_size * 0.24))

    draw_glow_ellipse(
        image,
        (
            int(size * 0.16),
            int(size * 0.70),
            int(size * 0.84),
            int(size * 0.95),
        ),
        "#00000088",
        max(6, size / 28),
    )

    draw_shadow(
        image,
        (
            icon_x + max(1, size // 96),
            icon_y + max(2, size // 42),
            icon_x + icon_size - max(1, size // 96),
            icon_y + icon_size + max(4, size // 32),
        ),
        outer_radius,
        "#0000006A",
        max(6, size / 30),
    )

    bezel_gradient = vertical_gradient((icon_size, icon_size), "#B3B8BF", "#585E65")
    bezel_mask = rounded_mask((icon_size, icon_size), outer_radius)
    paste_masked(image, bezel_gradient, (icon_x, icon_y), bezel_mask)

    inner_inset = max(4, int(icon_size * 0.035))
    face_x = icon_x + inner_inset
    face_y = icon_y + inner_inset
    face_size = icon_size - inner_inset * 2
    face_radius = max(10, int(outer_radius * 0.88))

    face_gradient = vertical_gradient((face_size, face_size), "#34373C", "#080A0D")
    face_mask = rounded_mask((face_size, face_size), face_radius)
    paste_masked(image, face_gradient, (face_x, face_y), face_mask)

    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        (icon_x, icon_y, icon_x + icon_size - 1, icon_y + icon_size - 1),
        radius=outer_radius,
        outline=rgba("#D0D4D9", 54),
        width=max(1, size // 256),
    )
    draw.rounded_rectangle(
        (face_x, face_y, face_x + face_size - 1, face_y + face_size - 1),
        radius=face_radius,
        outline=rgba("#FFFFFF", 28),
        width=max(1, size // 256),
    )

    gloss_height = int(face_size * 0.46)
    gloss = Image.new("RGBA", (face_size, gloss_height), (0, 0, 0, 0))
    gloss_pixels = gloss.load()
    height = max(gloss_height - 1, 1)
    for y in range(gloss_height):
        alpha = round(50 * (1 - y / height))
        for x in range(face_size):
            gloss_pixels[x, y] = (255, 255, 255, alpha)
    gloss_mask = rounded_mask((face_size, face_size), face_radius).crop((0, 0, face_size, gloss_height))
    paste_masked(image, gloss, (face_x, face_y), gloss_mask)

    belly = Image.new("RGBA", (face_size, int(face_size * 0.38)), (0, 0, 0, 0))
    belly_draw = ImageDraw.Draw(belly)
    belly_draw.ellipse(
        (
            int(face_size * 0.08),
            int(face_size * -0.58),
            int(face_size * 0.92),
            int(face_size * 0.62),
        ),
        fill=rgba("#FFFFFF", 28),
    )
    belly = belly.filter(ImageFilter.GaussianBlur(max(3, size / 56)))
    paste_masked(image, belly, (face_x, face_y + int(face_size * 0.62)), belly.split()[-1])

    return image, (face_x, face_y, face_size, face_size)


def draw_mark_shadow(draw: ImageDraw.ImageDraw, origin: tuple[int, int], cell: int, pattern: list[str], alpha: int) -> None:
    ox, oy = origin
    offset = max(1, round(cell * 0.16))
    shadow_fill = rgba("#000000", alpha)
    for row_index, row in enumerate(pattern):
        for column_index, char in enumerate(row):
            if char == ".":
                continue
            x = ox + column_index * cell + offset
            y = oy + row_index * cell + offset
            draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=shadow_fill)


def draw_mark(
    draw: ImageDraw.ImageDraw,
    origin: tuple[int, int],
    cell: int,
    palette: dict[str, tuple[int, int, int, int]],
    include_punctuation: bool,
    silhouette_only: bool = False,
) -> None:
    ox, oy = origin

    for row_index, row in enumerate(SCOUT_PATTERN):
        for column_index, char in enumerate(row):
            if char == ".":
                continue

            fill = palette["B" if silhouette_only else char]
            x = ox + column_index * cell
            y = oy + row_index * cell
            draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=fill)

    if include_punctuation:
        x = ox + 11 * cell
        for row_index in (1, 3, 5):
            y = oy + row_index * cell
            draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=palette["P"])


def render_app_icon(size: int) -> Image.Image:
    image, face = draw_app_shell(size)
    draw = ImageDraw.Draw(image)

    face_x, face_y, face_size, face_height = face
    mark_width_units = 12
    mark_height_units = 8
    cell = max(1, min(face_size // (mark_width_units + 3), face_height // (mark_height_units + 3)))
    mark_width = mark_width_units * cell
    mark_height = mark_height_units * cell
    origin_x = face_x + (face_size - mark_width) // 2 - max(1, cell // 3)
    origin_y = face_y + (face_height - mark_height) // 2

    palette = {
        "B": rgba("#F2F1EE"),
        "H": rgba("#FFFFFF"),
        "E": rgba("#1A1C20"),
        "P": rgba("#F7F7F3"),
    }

    draw_mark_shadow(draw, (origin_x, origin_y), cell, SCOUT_PATTERN, 82)
    draw_mark(draw, (origin_x, origin_y), cell, palette, include_punctuation=True)
    return image


def render_color_mark(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    cell = size / 8
    palette = {
        "B": rgba("#6E9FFF"),
        "H": rgba("#96BCFF"),
        "E": rgba("#112548"),
        "P": rgba("#6E9FFF"),
    }
    origin = (0, 0)
    for row_index, row in enumerate(SCOUT_PATTERN):
        for column_index, char in enumerate(row):
            if char == ".":
                continue
            x = round(origin[0] + column_index * cell)
            y = round(origin[1] + row_index * cell)
            x2 = round(origin[0] + (column_index + 1) * cell)
            y2 = round(origin[1] + (row_index + 1) * cell)
            draw.rectangle((x, y, x2 - 1, y2 - 1), fill=palette[char])
    return image


def render_template_mark(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    cell = size / 8
    fill = rgba("#000000")
    for row_index, row in enumerate(SCOUT_PATTERN):
        for column_index, char in enumerate(row):
            if char == ".":
                continue
            x = round(column_index * cell)
            y = round(row_index * cell)
            x2 = round((column_index + 1) * cell)
            y2 = round((row_index + 1) * cell)
            draw.rectangle((x, y, x2 - 1, y2 - 1), fill=fill)
    return image


def render_badge(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bezel_size = size
    bezel_gradient = vertical_gradient((bezel_size, bezel_size), "#A7ADB4", "#575D65")
    bezel_mask = rounded_mask((bezel_size, bezel_size), max(6, int(size * 0.23)))
    paste_masked(image, bezel_gradient, (0, 0), bezel_mask)

    inset = max(2, int(size * 0.06))
    face_size = size - inset * 2
    face_gradient = vertical_gradient((face_size, face_size), "#2D3136", "#090A0D")
    face_mask = rounded_mask((face_size, face_size), max(5, int(size * 0.19)))
    paste_masked(image, face_gradient, (inset, inset), face_mask)

    mark = render_color_mark(int(face_size * 0.64)).resize((int(face_size * 0.64), int(face_size * 0.64)), Image.Resampling.NEAREST)
    mx = inset + (face_size - mark.width) // 2
    my = inset + (face_size - mark.height) // 2
    image.alpha_composite(mark, (mx, my))
    return image


def write_app_icons() -> None:
    for filename, _, _, pixel_size in APP_ICON_SPECS:
        icon = render_app_icon(pixel_size)
        icon.save(APP_ICONSET_DIR / filename)
        icon.save(ICONSET_DIR / filename)


def write_internal_assets() -> None:
    for size in (14, 18, 32, 64):
        render_color_mark(size).save(INTERNAL_COLOR_DIR / f"scout-mark-{size}.png")

    for size in (18, 36):
        render_template_mark(size).save(INTERNAL_TEMPLATE_DIR / f"scout-template-{size}.png")

    for size in (32, 64):
        render_badge(size).save(INTERNAL_BADGE_DIR / f"scout-badge-{size}.png")


def write_appiconset_contents_json(path: Path) -> None:
    images = [
        {
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size,
        }
        for filename, size, scale, _ in APP_ICON_SPECS
    ]
    contents = {
        "images": images,
        "info": {
            "author": "app.openisland.dev",
            "version": 1,
        },
    }
    path.write_text(json.dumps(contents, indent=2) + "\n")


def build_icns() -> None:
    if ICNS_PATH.exists():
        ICNS_PATH.unlink()

    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET_DIR), "-o", str(ICNS_PATH)],
        check=True,
    )


def write_svg_master(path: Path) -> None:
    pixel_rects = []
    palette = {
        "B": "#F2F1EE",
        "H": "#FFFFFF",
        "E": "#1A1C20",
    }

    cell = 58
    origin_x = 248
    origin_y = 286
    for row_index, row in enumerate(SCOUT_PATTERN):
        for column_index, char in enumerate(row):
            if char == ".":
                continue
            pixel_rects.append(
                f'<rect x="{origin_x + column_index * cell}" y="{origin_y + row_index * cell}" width="{cell}" height="{cell}" fill="{palette[char]}"/>'
            )

    punctuation = []
    for row_index in (1, 3, 5):
        punctuation.append(
            f'<rect x="{origin_x + 11 * cell}" y="{origin_y + row_index * cell}" width="{cell}" height="{cell}" fill="#F7F7F3"/>'
        )

    svg = f"""<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bezel" x1="152" y1="140" x2="824" y2="824" gradientUnits="userSpaceOnUse">
      <stop stop-color="#B3B8BF"/>
      <stop offset="1" stop-color="#585E65"/>
    </linearGradient>
    <linearGradient id="face" x1="176" y1="164" x2="176" y2="848" gradientUnits="userSpaceOnUse">
      <stop stop-color="#34373C"/>
      <stop offset="1" stop-color="#080A0D"/>
    </linearGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
      <stop stop-color="white" stop-opacity="0.16"/>
      <stop offset="1" stop-color="white" stop-opacity="0"/>
    </linearGradient>
    <filter id="shadow" x="92" y="108" width="840" height="860" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feDropShadow dx="0" dy="36" stdDeviation="38" flood-color="black" flood-opacity="0.34"/>
    </filter>
    <filter id="markShadow" x="216" y="256" width="566" height="488" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feDropShadow dx="12" dy="12" stdDeviation="0" flood-color="black" flood-opacity="0.32"/>
    </filter>
  </defs>
  <ellipse cx="512" cy="830" rx="274" ry="94" fill="black" fill-opacity="0.26"/>
  <g filter="url(#shadow)">
    <rect x="140" y="128" width="744" height="744" rx="178" fill="url(#bezel)"/>
    <rect x="166" y="154" width="692" height="692" rx="154" fill="url(#face)"/>
    <rect x="166" y="154" width="692" height="324" rx="154" fill="url(#gloss)"/>
    <rect x="166.5" y="154.5" width="691" height="691" rx="153.5" stroke="white" stroke-opacity="0.08"/>
    <rect x="140.5" y="128.5" width="743" height="743" rx="177.5" stroke="white" stroke-opacity="0.14"/>
  </g>
  <g filter="url(#markShadow)">
    {"".join(pixel_rects)}
    {"".join(punctuation)}
  </g>
</svg>
"""
    path.write_text(svg)


if __name__ == "__main__":
    main()
