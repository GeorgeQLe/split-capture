#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
master_svg="$repository_root/branding/split-capture-icon.svg"
master_png="$repository_root/branding/split-capture-icon-1024.png"
macos_set="$repository_root/frontend/cmake/macos/Assets.xcassets/AppIcon.appiconset"
linux_icons="$repository_root/frontend/cmake/linux/icons"
windows_frontend="$repository_root/frontend/cmake/windows/split-capture.ico"
windows_bundle="$repository_root/cmake/bundle/windows/split-capture.ico"
packaging_icns="$repository_root/branding/assets/SplitCapture.icns"

if command -v magick >/dev/null 2>&1; then
  imagemagick=magick
elif command -v convert >/dev/null 2>&1; then
  imagemagick=convert
else
  echo "error: ImageMagick (magick or convert) is required" >&2
  exit 2
fi

[[ -f "$master_svg" ]] || {
  echo "error: missing master SVG: $master_svg" >&2
  exit 2
}

mkdir -p "$macos_set" "$linux_icons" "$(dirname "$windows_frontend")" \
  "$(dirname "$windows_bundle")" "$(dirname "$packaging_icns")"

"$imagemagick" -background none "$master_svg" -resize 1024x1024 -depth 8 "$master_png"

render_png() {
  local size="$1"
  local destination="$2"
  "$imagemagick" "$master_png" -filter Lanczos -resize "${size}x${size}" \
    -strip -depth 8 -define png:color-type=6 "$destination"
}

render_png 16 "$macos_set/icon_16x16.png"
render_png 32 "$macos_set/icon_16x16@2x.png"
render_png 32 "$macos_set/icon_32x32.png"
render_png 64 "$macos_set/icon_32x32@2x.png"
render_png 128 "$macos_set/icon_128x128.png"
render_png 256 "$macos_set/icon_128x128@2x.png"
render_png 256 "$macos_set/icon_256x256.png"
render_png 512 "$macos_set/icon_256x256@2x.png"
render_png 512 "$macos_set/icon_512x512.png"
render_png 1024 "$macos_set/icon_512x512@2x.png"

render_png 128 "$linux_icons/split-capture-128.png"
render_png 256 "$linux_icons/split-capture-256.png"
render_png 512 "$linux_icons/split-capture-512.png"
cp "$master_svg" "$linux_icons/split-capture-scalable.svg"

"$imagemagick" "$master_png" -background none \
  -define icon:auto-resize=256,128,64,48,32,24,16 "$windows_frontend"
cp "$windows_frontend" "$windows_bundle"

if command -v iconutil >/dev/null 2>&1; then
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/split-capture-icons.XXXXXX")"
  trap 'rm -rf -- "$temporary_directory"' EXIT
  iconset="$temporary_directory/SplitCapture.iconset"
  mkdir "$iconset"
  cp "$macos_set/icon_16x16.png" "$iconset/icon_16x16.png"
  cp "$macos_set/icon_16x16@2x.png" "$iconset/icon_16x16@2x.png"
  cp "$macos_set/icon_32x32.png" "$iconset/icon_32x32.png"
  cp "$macos_set/icon_32x32@2x.png" "$iconset/icon_32x32@2x.png"
  cp "$macos_set/icon_128x128.png" "$iconset/icon_128x128.png"
  cp "$macos_set/icon_128x128@2x.png" "$iconset/icon_128x128@2x.png"
  cp "$macos_set/icon_256x256.png" "$iconset/icon_256x256.png"
  cp "$macos_set/icon_256x256@2x.png" "$iconset/icon_256x256@2x.png"
  cp "$macos_set/icon_512x512.png" "$iconset/icon_512x512.png"
  cp "$macos_set/icon_512x512@2x.png" "$iconset/icon_512x512@2x.png"
  if ! iconutil --convert icns --output "$packaging_icns" "$iconset" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1; then
      python3 "$script_directory/pack-icns.py" "$iconset" "$packaging_icns"
      echo "warning: iconutil rejected the classic iconset; used the PNG-backed ICNS fallback" >&2
    else
      echo "error: iconutil rejected the iconset and python3 is unavailable for the fallback" >&2
      exit 2
    fi
  fi
else
  echo "warning: iconutil not found; skipped macOS packaging ICNS" >&2
fi

echo "Generated Split Capture icons from branding/split-capture-icon.svg"
