#!/usr/bin/env python3
"""Mean luminance (0-255) of a display, captured with screencapture -D.
Usage: lum.py <displayIndex 1-based, screencapture's order> [label]
Overlays are compositor windows, so a capture sees them; a reading with no
overlay up is the control every dimmed reading is compared against."""
import subprocess, sys, tempfile
from PIL import Image, ImageStat
d = sys.argv[1]; label = sys.argv[2] if len(sys.argv) > 2 else ""
f = tempfile.mktemp(suffix=".png")
subprocess.run(["screencapture", "-x", "-D", d, f], check=True)
im = Image.open(f).convert("L")
print(f"display {d} {label}: mean luminance {ImageStat.Stat(im).mean[0]:.1f} of 255 ({im.size[0]}x{im.size[1]})")
