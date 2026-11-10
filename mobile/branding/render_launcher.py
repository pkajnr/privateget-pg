#!/usr/bin/env python3
"""Rasterize PG's owned vector mark into mobile launcher and UI icons."""
from pathlib import Path
import json
import plistlib
import re
import cairosvg

root = Path(__file__).resolve().parents[1]
svg = (root / 'branding/pg_icon.svg').read_bytes()

def render(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(bytestring=svg, write_to=str(path),
                     output_width=size, output_height=size)

android = root / 'android/app/src/main'
manifest = android / 'AndroidManifest.xml'
xml = manifest.read_text()
if re.search(r'android:label="[^"]*"', xml):
    xml = re.sub(r'android:label="[^"]*"', 'android:label="PG"', xml, count=1)
else:
    raise RuntimeError('Missing android:label in generated AndroidManifest.xml')
manifest.write_text(xml)

# Android legacy/modern masked launcher icon resources.
for density, pixels in {
    'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
    'xxhdpi': 144, 'xxxhdpi': 192,
}.items():
    for name in ('ic_launcher.png', 'ic_launcher_round.png'):
        render(android / 'res' / f'mipmap-{density}' / name, pixels)

# The same coherent brand mark is available in the Flutter header.
render(root / 'assets/pg_brandmark.png', 256)

iconset = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
contents = iconset / 'Contents.json'
if contents.exists():
    icons = json.loads(contents.read_text())
    for entry in icons.get('images', []):
        filename = entry.get('filename')
        if not filename:
            continue
        square = float(entry['size'].split('x')[0])
        scale = int(entry['scale'].rstrip('x'))
        render(iconset / filename, int(round(square * scale)))

ios_plist = root / 'ios/Runner/Info.plist'
if ios_plist.exists():
    with ios_plist.open('rb') as stream:
        data = plistlib.load(stream)
    data['CFBundleDisplayName'] = 'PG'
    data['CFBundleName'] = 'PG'
    with ios_plist.open('wb') as stream:
        plistlib.dump(data, stream)

print('PG launcher icon and platform display names generated.')
