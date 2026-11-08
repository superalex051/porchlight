#!/usr/bin/env bash
# Renders the app icon set and the menu bar glyph from the SVG sources in docs/design, then checks
# every PNG's pixel size with sips. Writes only into App/Resources/Assets.xcassets.
#
#   16 px and 32 px (icon_16x16, icon_16x16@2x, icon_32x32)  from porch-light-icon-small.svg
#   64 px and up (icon_32x32@2x to icon_512x512@2x)           from porch-light-icon.svg
#   18 px menu bar glyph (@1x), drawn pixel by pixel          from porch-light-menubar-1x.svg
#   36 px menu bar glyph (@2x)                                from porch-light-menubar.svg
#
# 64 px comes from the full drawing: it keeps the chain, roof and flame and matches 128 px and up,
# where the small drawing doubled looks blocky.
#
# Needs rsvg-convert (Homebrew: librsvg). Set RSVG_CONVERT to use a different one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RSVG="${RSVG_CONVERT:-}"
if [ -z "$RSVG" ]; then
    RSVG="$(command -v rsvg-convert || true)"
fi
if [ -z "$RSVG" ] && [ -x /opt/homebrew/bin/rsvg-convert ]; then
    RSVG=/opt/homebrew/bin/rsvg-convert
fi
if [ -z "$RSVG" ]; then
    echo "render-icons: rsvg-convert not found. Install it with: brew install librsvg" >&2
    exit 1
fi

FULL=docs/design/porch-light-icon.svg
SMALL=docs/design/porch-light-icon-small.svg
GLYPH=docs/design/porch-light-menubar.svg
GLYPH_1X=docs/design/porch-light-menubar-1x.svg
ICONSET=App/Resources/Assets.xcassets/AppIcon.appiconset
GLYPHSET=App/Resources/Assets.xcassets/MenuBarGlyph.imageset

for source in "$FULL" "$SMALL" "$GLYPH" "$GLYPH_1X"; do
    [ -f "$source" ] || { echo "render-icons: missing $source" >&2; exit 1; }
done
mkdir -p "$ICONSET" "$GLYPHSET"

# Different librsvg versions can anti-alias differently, so the log says which one rendered.
echo "render-icons: using $RSVG ($("$RSVG" --version | sed -n 1p))"

failures=0

# render <source svg> <pixels> <output png>
render() {
    local source="$1" pixels="$2" output="$3" width height
    "$RSVG" --width "$pixels" --height "$pixels" --format png --output "$output" "$source"
    width="$(sips -g pixelWidth "$output" | awk '/pixelWidth/ { print $2 }')"
    height="$(sips -g pixelHeight "$output" | awk '/pixelHeight/ { print $2 }')"
    if [ "$width" = "$pixels" ] && [ "$height" = "$pixels" ]; then
        echo "render-icons: $output ${width}x${height} from $(basename "$source")"
    else
        echo "render-icons: $output is ${width}x${height}, expected ${pixels}x${pixels}" >&2
        failures=$((failures + 1))
    fi
}

render "$SMALL" 16 "$ICONSET/icon_16x16.png"
render "$SMALL" 32 "$ICONSET/icon_16x16@2x.png"
render "$SMALL" 32 "$ICONSET/icon_32x32.png"
render "$FULL" 64 "$ICONSET/icon_32x32@2x.png"
render "$FULL" 128 "$ICONSET/icon_128x128.png"
render "$FULL" 256 "$ICONSET/icon_128x128@2x.png"
render "$FULL" 256 "$ICONSET/icon_256x256.png"
render "$FULL" 512 "$ICONSET/icon_256x256@2x.png"
render "$FULL" 512 "$ICONSET/icon_512x512.png"
render "$FULL" 1024 "$ICONSET/icon_512x512@2x.png"

render "$GLYPH_1X" 18 "$GLYPHSET/menubar-glyph.png"
render "$GLYPH" 36 "$GLYPHSET/menubar-glyph@2x.png"

if [ "$failures" -gt 0 ]; then
    echo "render-icons: FAILED, $failures PNG(s) have the wrong size" >&2
    exit 1
fi
echo "render-icons: OK"
