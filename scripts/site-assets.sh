#!/bin/bash
# Copies the rendered pictures the site uses out of docs/media.
#
# The site does not reference ../docs/media directly, because a static host is given the site/ folder alone and a
# relative path out of it resolves to nothing. Re-run this after --render-assets, which is what actually draws
# them (AssetRenderer.swift); this only moves the ones the pages use.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p site/img
for f in demo.gif expanded.png edge-left.png edge-right-panel.png signal-rings.png compact-top.png settings.png; do
    cp "docs/media/$f" "site/img/$f"
done
cp build/AppIcon.iconset/icon_256x256.png site/img/icon.png 2>/dev/null \
    || echo "no build/AppIcon.iconset; run scripts/build.sh once for the icon"

echo "site/img: $(ls site/img | wc -l | tr -d ' ') files, $(du -sh site/img | cut -f1)"
