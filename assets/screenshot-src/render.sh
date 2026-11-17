#!/bin/sh
# Regenerate assets/screenshot.png: SF Symbol PNGs → HTML mockup → headless Chrome → pngquant.
set -e
cd "$(dirname "$0")"
swift sym.swift
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,690 --screenshot="$PWD/out.png" "file://$PWD/index.html"
pngquant --quality 80-95 --speed 1 -f -o ../screenshot.png out.png && rm out.png
