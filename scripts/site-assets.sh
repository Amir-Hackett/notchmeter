#!/bin/bash
# Copies the rendered pictures the site uses out of docs/media.
#
# The site does not reference ../docs/media directly, because a static host is given the site/ folder alone and a
# relative path out of it resolves to nothing. Re-run this after --render-assets, which is what actually draws
# them (AssetRenderer.swift); this only moves the ones the pages use.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p site/img
for f in demo.gif expanded.png edge-left.png edge-right-panel.png signal-rings.png compact-top.png permission.png question.png settings.png dashboard.png; do
    cp "docs/media/$f" "site/img/$f"
done
# The brand mark: the icon macOS draws for the built bundle, which is the Liquid Glass one once the bundle carries
# the compiled Assets.car and the flat .icns before that (docs/release.md, "The icon"). The iconset is the fallback
# for a tree with no built app in it.
swift scripts/render-app-icon.swift build/Notchmeter.app site/img/icon.png 256 2>/dev/null \
    || cp build/AppIcon.iconset/icon_256x256.png site/img/icon.png 2>/dev/null \
    || echo "no built app and no build/AppIcon.iconset; run scripts/build.sh once for the icon"

echo "site/img: $(ls site/img | wc -l | tr -d ' ') files, $(du -sh site/img | cut -f1)"
