#!/usr/bin/env python3
"""Make the U-Boot boot logo: logo.bmp, 1280x800, 24-bit, uncompressed.

The picture is centred on a black screen (U-Boot clears the screen to black
before it draws the logo); transparent parts become black. Its visible part is
scaled to HEIGHT percent of the screen height, keeping the proportions.

    make-logo.py picture.png [logo.bmp] [--height 40] [--bg 000000]

Needs Pillow (apt install python3-pil, or pip install pillow).
"""
import argparse

from PIL import Image

W, H = 1280, 800


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('out', nargs='?', default='logo.bmp')
    ap.add_argument('--height', type=float, default=40, help='logo height, %% of the screen (default 40)')
    ap.add_argument('--bg', default='000000', help='background colour, RRGGBB (default black)')
    a = ap.parse_args()

    bg = tuple(int(a.bg[i:i + 2], 16) for i in (0, 2, 4))
    im = Image.open(a.src).convert('RGBA')
    box = im.getchannel('A').getbbox() or (0, 0, im.width, im.height)
    im = im.crop(box)
    scale = min(H * a.height / 100 / im.height, W * 0.9 / im.width)
    size = (max(1, round(im.width * scale)), max(1, round(im.height * scale)))
    im = im.resize(size, Image.LANCZOS)

    screen = Image.new('RGB', (W, H), bg)
    screen.paste(im, ((W - size[0]) // 2, (H - size[1]) // 2), im)
    screen.save(a.out, 'BMP')   # BITMAPINFOHEADER, 24-bit, bottom-up, no compression
    print(f'{a.out}: {W}x{H}, logo {size[0]}x{size[1]}')


if __name__ == '__main__':
    main()
