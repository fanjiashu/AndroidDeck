#!/usr/bin/env python3
"""Convert the designed alpha PNG into all standard macOS icon sizes."""
import pathlib, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = root/'assets/androiddeck-icon.png'
destination = root/'assets/AndroidDeck.icns'
if not source.is_file():
    raise SystemExit('缺少 assets/androiddeck-icon.png')
(root/'data').mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='androiddeck-icon-', dir=root/'data') as work:
    iconset = pathlib.Path(work)/'AndroidDeck.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            name = f'icon_{size}x{size}{suffix}.png'
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', '-z', str(size*scale),
                str(size*scale), str(source), '--out', str(iconset/name)],
                check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)
print(destination)
