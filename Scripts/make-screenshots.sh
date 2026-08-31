#!/usr/bin/env bash
# Generates the served screenshot derivatives from the masters.
#
# Masters live in Site/screenshots/ and are never published: Site/assets is
# mirrored into docs/ wholesale, so a master kept there would be cloned by
# every visitor at full size.
#
# Three formats, in the order a browser tries them: AVIF, then WebP, then a
# 256-colour PNG for anything that reads neither. Each is emitted at 1280 and
# 2560 wide so the srcset can pick by density.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Site/screenshots"
OUT="Site/assets/screenshots"

# sips encodes AVIF natively; it cannot encode WebP, which is why cwebp is
# here. Both are maintainer tools, not build dependencies: a fresh clone builds
# the site from what this script has already committed.
command -v cwebp >/dev/null || { echo "error: cwebp not found (brew install webp)" >&2; exit 1; }
command -v magick >/dev/null || { echo "error: magick not found (brew install imagemagick)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

printf "%-34s %9s %9s\n" "screenshot" "webp" "png"
total_master=0; total_webp=0; total_png=0

for master in "$SRC"/*@2x.png; do
  base="$(basename "$master" "@2x.png")"

  cwebp -q 80 -quiet "$master" -o "$OUT/$base@2x.webp"
  cwebp -q 80 -quiet -resize 1280 0 "$master" -o "$OUT/$base.webp"

  # The fallback only reaches a browser that cannot read WebP, so it is
  # quantised: flat window chrome takes 256 colours without visible banding.
  magick "$master" -colors 256 "$OUT/$base@2x.png"

  m=$(stat -f%z "$master")
  w=$(stat -f%z "$OUT/$base@2x.webp"); p=$(stat -f%z "$OUT/$base@2x.png")
  total_master=$((total_master+m))
  total_webp=$((total_webp+w)); total_png=$((total_png+p))
  printf "%-34s %8dK %8dK\n" "$base" $((w/1024)) $((p/1024))
done

echo
printf "masters (not served) %6dK\n" $((total_master/1024))
printf "webp  @2x            %6dK\n" $((total_webp/1024))
printf "png   @2x fallback   %6dK\n" $((total_png/1024))
# The manifest is what makes a stale derivative a test failure rather than a
# thing you notice on the live site: retaking a master changes its hash, and
# the hash is only rewritten here, by the run that regenerates its derivatives.
( cd "$SRC" && shasum -a 256 *@2x.png | sort -k2 ) > "$SRC/manifest.txt"

echo "wrote $(find "$OUT" -type f | wc -l | tr -d ' ') files to $OUT"
echo "wrote $SRC/manifest.txt ($(wc -l < "$SRC/manifest.txt" | tr -d ' ') masters)"
