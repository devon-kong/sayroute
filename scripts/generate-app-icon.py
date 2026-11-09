#!/usr/bin/env python3
"""Render the existing SayRoute mark on a clean, subtly raised macOS tile.

Requires Pillow. Run from any directory; the original brand master stays intact.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent.parent
SCALE = 2
SIZE = 1024


def tile_mask(box, radius):
    mask = Image.new('L', (SIZE * SCALE, SIZE * SCALE))
    ImageDraw.Draw(mask).rounded_rectangle(
        tuple(round(x * SCALE) for x in box), radius=radius * SCALE, fill=255)
    return mask


def render():
    size = SIZE * SCALE
    rim = tile_mask((100, 100, 924, 924), 184)
    face = tile_mask((100, 100, 924, 919), 184)
    canvas = Image.new('RGBA', (size, size))
    # Two neutral shadows, both contained within the transparent outer margin.
    for blur, offset, opacity in [(13, 13, 58), (3, 4, 25)]:
        shifted = Image.new('L', (size, size))
        shifted.paste(rim, (0, offset * SCALE))
        alpha = shifted.filter(ImageFilter.GaussianBlur(blur * SCALE))
        alpha = alpha.point(lambda x: round(x * opacity / 255))
        layer = Image.new('RGBA', (size, size), (35, 39, 46, 0))
        layer.putalpha(alpha)
        canvas = Image.alpha_composite(canvas, layer)
    # Slim lower rim, rather than a thick extrusion.
    rim_layer = Image.new('RGBA', (size, size), (203, 206, 211, 255))
    rim_layer.putalpha(rim)
    canvas = Image.alpha_composite(canvas, rim_layer)
    gradient = Image.new('RGBA', (1, size))
    gradient.putdata([
        (v, v, min(255, v + 1), 255)
        for y in range(size)
        for v in [round(255 - 15 * max(0, min(1, (y / SCALE - 100) / 819)))]
    ])
    surface = gradient.resize((size, size))
    surface.putalpha(face)
    canvas = Image.alpha_composite(canvas, surface)
    # One-pixel inset highlight and a low-contrast outer edge catch the light.
    edge = Image.new('RGBA', (size, size))
    draw = ImageDraw.Draw(edge)
    draw.rounded_rectangle((100*SCALE, 100*SCALE, 924*SCALE, 919*SCALE),
                           radius=184*SCALE, outline=(155, 160, 169, 55), width=SCALE)
    draw.rounded_rectangle((102*SCALE, 102*SCALE, 922*SCALE, 917*SCALE),
                           radius=182*SCALE, outline=(255, 255, 255, 150), width=SCALE)
    canvas = Image.alpha_composite(canvas, edge)
    # Recover only the original dark mark, discarding the photographic white
    # paper texture. Placement matches the previous installed icon exactly.
    master = Image.open(ROOT / 'docs/brand/sayroute-icon-master.png').convert('RGB')
    mask = ImageOps.invert(ImageOps.grayscale(master))
    mask = mask.point(lambda x: 0 if x < 32 else (255 if x > 223 else round((x-32)*255/191)))
    mask = mask.resize((824*SCALE, 824*SCALE), Image.Resampling.LANCZOS)
    mark = Image.new('RGBA', mask.size, (7, 8, 9, 255))
    mark.putalpha(mask)
    canvas.alpha_composite(mark, (100*SCALE, 100*SCALE))
    return canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'SayRoute/Resources/AppIcon.icns')
    args = parser.parse_args()
    image = render()
    # Keep fully transparent outer borders; no opaque white speckles or clipping.
    alpha = image.getchannel('A')
    assert alpha.getextrema() == (0, 255)
    assert alpha.crop((0, 0, SIZE, 12)).getbbox() is None
    assert alpha.crop((0, SIZE-12, SIZE, SIZE)).getbbox() is None
    image.save(ROOT / 'docs/brand/sayroute-icon-native.png')
    with tempfile.TemporaryDirectory(prefix='sayroute-icon-') as temp:
        iconset = Path(temp) / 'AppIcon.iconset'
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = '@2x' if scale == 2 else ''
                icon = image.resize((pixels, pixels), Image.Resampling.LANCZOS)
                icon.save(iconset / f'icon_{points}x{points}{suffix}.png')
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(args.output)], check=True)
    print(f'Created {args.output}')


if __name__ == '__main__':
    main()
