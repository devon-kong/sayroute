#!/usr/bin/env python3
"""Regression checks for deterministic artwork, alpha, and all ICNS sizes."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True
from PIL import Image, ImageChops, ImageOps

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('generate_app_icon', ROOT / 'scripts/generate-app-icon.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class AppIconTests(unittest.TestCase):
    def test_canonical_artwork_matches_renderer(self):
        expected = generator.render()
        actual = Image.open(ROOT / 'docs/brand/sayroute-icon-native.png').convert('RGBA')
        self.assertIsNone(ImageChops.difference(actual, expected).getbbox())
        alpha = actual.getchannel('A')
        for box in [(0, 0, 1024, 12), (0, 1012, 1024, 1024),
                    (0, 0, 12, 1024), (1012, 0, 1024, 1024)]:
            self.assertIsNone(alpha.crop(box).getbbox())
        # Gray shadow, never floating opaque white pixels outside the tile.
        self.assertGreater(actual.getpixel((512, 936))[3], 0)
        self.assertLess(actual.getpixel((512, 936))[3], 150)
        self.assertGreater(actual.getpixel((512, 120))[0], actual.getpixel((512, 895))[0])
        self.assertEqual(actual.getpixel((512, 512))[3], 255)

    def test_all_icns_representations(self):
        with tempfile.TemporaryDirectory(prefix='sayroute-icon-test-') as temp:
            destination = Path(temp) / 'AppIcon.iconset'
            subprocess.run(['iconutil', '-c', 'iconset', str(ROOT / 'SayRoute/Resources/AppIcon.icns'),
                            '-o', str(destination)], check=True)
            self.assertEqual(len(list(destination.glob('*.png'))), 10)
            for points in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    suffix = '@2x' if scale == 2 else ''
                    icon = Image.open(destination / f'icon_{points}x{points}{suffix}.png')
                    self.assertEqual(icon.size, (points * scale, points * scale))
                    self.assertEqual(icon.mode, 'RGBA')
                    self.assertEqual(icon.getpixel((0, 0))[3], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
