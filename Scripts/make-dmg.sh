#!/usr/bin/env bash
# Packages the built app into the disk image the download page promises.
#
# The site's first step reads "Download and open the disk image / Drag DDCC into
# your Applications folder", so the window has to contain exactly two things:
# the app, and somewhere to drag it to. That is the whole design. No background
# art and no saved window geometry, because both would mean driving Finder over
# AppleScript, and Finder needs a logged-in GUI session that a CI runner does
# not have.
#
# The name carries no version. The asset is DDCC.dmg release after release, so
# releases/latest/download/DDCC.dmg is a permanent address and no page needs
# editing when a version ships.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="DDCC.app"
DMG="DDCC.dmg"
# What Finder prints in the title bar of the mounted window.
VOLUME_NAME="DDCC"

# shellcheck source=/dev/null
[ -f Scripts/signing.local.sh ] && source Scripts/signing.local.sh
IDENTITY="${DDCC_SIGNING_IDENTITY:--}"

if [ ! -d "$APP" ]; then
  echo "error: $APP does not exist. Run Scripts/make-app.sh --release first." >&2
  exit 1
fi

# A disk image is a container, and Gatekeeper checks the container as well as
# what it holds. Signing and notarizing this file while the app inside it was
# never notarized would produce something that opens cleanly and then refuses
# to launch -- a worse failure than refusing at the door, because the visitor
# has already decided to trust it.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "error: $APP carries no notarization ticket." >&2
  echo "Run Scripts/make-app.sh --release, which notarizes and staples it." >&2
  exit 1
fi

if [ "$IDENTITY" = "-" ]; then
  echo "error: the disk image needs a Developer ID; DDCC_SIGNING_IDENTITY is unset." >&2
  exit 1
fi

# shellcheck source=Scripts/notarize.sh
source Scripts/notarize.sh
ddcc_notary_resolve

STAGING="$(mktemp -d -t ddcc-dmg)"
# Runs on the failure paths too. Without it a rejected notarization leaves a
# copy of the signed app in /var/folders with nothing pointing at it.
trap 'rm -rf "$STAGING"' EXIT

# ditto rather than cp -R: the bundle is signed, and a copy that drops the
# extended attributes or flattens a symlink invalidates the signature. The
# breakage would not appear here -- it appears when a visitor tries to open it.
ditto "$APP" "$STAGING/$APP"

# The drop target. A symlink, so it costs no space in the image and always
# resolves to the Applications folder of whatever machine mounts it.
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
# UDZO is read-only and compressed, which is what a download wants. HFS+ rather
# than APFS: the app needs macOS 15, but the disk image should still mount on an
# older Mac so someone can look inside it before deciding.
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  -quiet \
  "$DMG"

# --timestamp for the same reason the app carries one: a signature Apple will
# notarize has to be timestamped by Apple's server.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

ddcc_notarize_container "$DMG"
ddcc_staple "$DMG"

# The check that matches what a visitor's Mac actually does with a downloaded
# image. --type open with the primary-signature context is the disk-image
# assessment; --type exec would assess it as if it were an executable and
# report a failure that means nothing here.
spctl --assess --type open --context context:primary-signature -vv "$DMG"

DMG_BYTES="$(stat -f%z "$DMG")"
APP_KB="$(du -sk "$APP" | cut -f1)"

# The download page publishes this app's own size as evidence for the claims
# beside it -- no account, no telemetry, no network. A 4 MB download is the
# cheapest corroboration of those, because there is no room in it for an
# analytics SDK and a sign-in flow. Published, it is also a claim that goes
# false on its own as features land, and nothing about that failure is loud:
# the page just quietly overstates how small the app is.
#
# So the claim is checked against the artifact at the one moment it can change,
# using the real disk image rather than any proxy for it. Read FROM the page
# rather than from a constant kept beside it, so there is one figure and not
# two free to disagree.
CLAIM_LINE="$(grep -oE '[0-9.]+ MB download, [0-9.]+ MB installed' Site/pages/download.html || true)"
if [ -z "$CLAIM_LINE" ]; then
  echo "error: no footprint claim found in Site/pages/download.html" >&2
  echo "It published one at the time this check was written. If the wording changed," >&2
  echo "update this pattern; if the claim was removed, remove this check with it." >&2
  exit 1
fi
CLAIMED_DMG_MB="${CLAIM_LINE%% MB download*}"
CLAIMED_APP_MB="$(printf '%s' "$CLAIM_LINE" | sed -E 's/.*, ([0-9.]+) MB installed/\1/')"

# awk rather than shell arithmetic: the claims carry decimals, and bash
# compares those as strings.
if awk -v a="$DMG_BYTES" -v c="$CLAIMED_DMG_MB" 'BEGIN { exit !(a / 1000000 > c) }'; then
  printf 'error: the disk image is %.2f MB but the download page claims %s MB\n' \
    "$(awk -v a="$DMG_BYTES" 'BEGIN { print a / 1000000 }')" "$CLAIMED_DMG_MB" >&2
  echo "Update the readout list in Site/pages/download.html, rebuild the site," >&2
  echo "and see docs/known-gaps.md in drive-clean-notes." >&2
  exit 1
fi
if awk -v a="$APP_KB" -v c="$CLAIMED_APP_MB" 'BEGIN { exit !(a / 1024 > c) }'; then
  printf 'error: the app is %.2f MB installed but the download page claims %s MB\n' \
    "$(awk -v a="$APP_KB" 'BEGIN { print a / 1024 }')" "$CLAIMED_APP_MB" >&2
  echo "Update the readout list in Site/pages/download.html and rebuild the site." >&2
  exit 1
fi

echo "built $DMG"
echo "  size    $(du -h "$DMG" | cut -f1)"
echo "  sha256  $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  claim   $CLAIM_LINE  (checked against this build)"
