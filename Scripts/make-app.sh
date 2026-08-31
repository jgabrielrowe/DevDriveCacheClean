#!/usr/bin/env bash
# Assembles DevDriveCacheClean.app around the SwiftPM release executable.
#
# The bundle identifier is the entire point: TCC keys Full Disk Access on it,
# and without one macOS silently denies reads and every scan total is a floor.
#
# Two modes. The default builds for this machine and stops at signing, which is
# what a working copy wants. --release additionally hardens the runtime,
# notarizes with Apple and staples the ticket, which is what a downloadable
# build needs and what nothing else here should pay for.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
# The bundle FILENAME is what Finder, Launchpad and the Dock print under the
# icon. CFBundleDisplayName does not override it — macOS ignores that key for
# .app bundles so a bundle cannot claim a name its file does not have
# (verified 2026-08-12: with CFBundleDisplayName=DDCC set, displayName(atPath:)
# still returned DevDriveCacheClean). Renaming the file is the only lever.
# The executable inside, CFBundleName and the bundle id all stay long-form.
APP="DDCC.app"
# shellcheck source=/dev/null
[ -f Scripts/signing.local.sh ] && source Scripts/signing.local.sh
# Both overrides are read from signing.local.sh, so a fork that sets one gets
# the other honoured too, rather than shipping with the default bundle id.
BUNDLE_ID="${DDCC_BUNDLE_ID:-com.jgabrielrowe.devdrivecacheclean}"
IDENTITY="${DDCC_SIGNING_IDENTITY:--}"
INSTALL=0
RELEASE=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Checked here rather than at the notarization step, which is 150 lines and one
# full universal build later. Apple will not notarize an ad-hoc signature, so a
# release run without a real identity is already doomed at the point it starts.
if [ "$RELEASE" = "1" ] && [ "$IDENTITY" = "-" ]; then
  echo "error: --release needs a Developer ID; DDCC_SIGNING_IDENTITY is unset." >&2
  echo "Apple does not notarize ad-hoc signatures, so this build could not ship." >&2
  exit 1
fi

# Resolved before the build for the same reason: a missing credential should
# cost a second, not a universal compile. Scripts/notarize.sh explains the two
# credential forms and why there are two.
if [ "$RELEASE" = "1" ]; then
  # shellcheck source=Scripts/notarize.sh
  source Scripts/notarize.sh
  ddcc_notary_resolve
fi

# Unset means ad-hoc, which is intentional: a fresh clone builds with no setup.
# Set-but-missing is a misconfiguration. Failing loudly matters because silently
# ad-hoc-signing over the granted copy would cost the FDA grant with no indication why.
if [ "$IDENTITY" != "-" ] \
   && ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "error: signing identity '$IDENTITY' is not in the keychain." >&2
  echo "Run Scripts/create-signing-cert.sh, or unset DDCC_SIGNING_IDENTITY for ad-hoc." >&2
  exit 1
fi

# Universal, because the site claims Apple silicon and Intel and a host-only
# build quietly makes that false: an arm64 slice will not launch on an Intel
# Mac at all. Both arches are passed to --show-bin-path too, or it reports the
# host's directory rather than the merged one.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product DevDriveCacheClean
BIN_PATH="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
# Falls back to 0 when there's no .git (a GitHub source tarball) or on a
# shallow clone (where the count is small but harmless: TCC keys on the
# bundle identifier, not CFBundleVersion).
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Committed rather than generated here: building it needs a Swift toolchain run
# per invocation for art that changes once a year. Scripts/make-icon.swift
# regenerates it from Resources/AppIcon.png when the art does change.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Regenerated every build rather than committed: an out-of-date help index
# still opens and still searches, it just answers wrong. The icon can be
# committed because a stale icon is visible; a stale index is not.
#
# hiutil runs inside HelpBookBuilder itself (HelpIndex.index, invoked after
# the bundle is written) rather than as a second, hand-typed invocation here.
# Two copies of the same argument list previously let the tested list and the
# executed list drift apart with no test able to catch it.
HELP_BOOK="$APP/Contents/Resources/DDCC.help"
swift run -c release HelpBookBuilder --build "$HELP_BOOK"

sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD_NUMBER|g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

cp "$BIN_PATH/DevDriveCacheClean" "$APP/Contents/MacOS/DevDriveCacheClean"

# No --deep: it is deprecated, and nothing in this bundle is nested.
#
# The hardened runtime is scoped to --release rather than applied always. It
# stops the debugger attaching, so carrying it in a dev build would cost lldb on
# every local run; the notary service rejects any submission without it, so
# omitting it from a release build means nothing can ship. Neither setting is
# right for both jobs, which is why the flag exists.
#
# --timestamp travels with it. A notarized signature must carry a secure
# timestamp from Apple's server, and an ad-hoc dev signature cannot have one --
# there is no identity to issue it against.
SIGN_OPTS=(--force --sign "$IDENTITY")
if [ "$RELEASE" = "1" ]; then
  SIGN_OPTS+=(--options runtime --timestamp)
fi
codesign "${SIGN_OPTS[@]}" "$APP"

# Verify the premise rather than assume it. A typo here would silently
# reproduce the exact bug this script exists to fix, while looking like success.
PLIST_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$PLIST_ID" != "$BUNDLE_ID" ]; then
  echo "error: Info.plist CFBundleIdentifier is '$PLIST_ID', expected '$BUNDLE_ID'" >&2
  exit 1
fi

# A missing icon is not a build failure to macOS — it silently falls back to
# the blank document icon, which looks like a broken app rather than a missing
# file. Check that the plist's name and the file on disk actually agree.
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
if [ ! -f "$APP/Contents/Resources/$ICON_NAME.icns" ]; then
  echo "error: Info.plist names icon '$ICON_NAME' but Contents/Resources/$ICON_NAME.icns is missing" >&2
  exit 1
fi

# Help Viewer opens an empty window with no error when CFBundleHelpBookName
# disagrees with the book's HPDBookTitle or with index.html's AppleTitle.
# Nothing about that failure says which of the three is wrong, so check all.
BOOK_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleHelpBookName' "$APP/Contents/Info.plist")"
BOOK_FOLDER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleHelpBookFolder' "$APP/Contents/Info.plist")"
if [ ! -d "$APP/Contents/Resources/$BOOK_FOLDER" ]; then
  echo "error: Info.plist names help book '$BOOK_FOLDER' but Contents/Resources/$BOOK_FOLDER is missing" >&2
  exit 1
fi
# Derived here rather than reused: hiutil lives inside HelpBookBuilder, so
# this script holds no other definition of the localised resources path.
HELP_LPROJ="$HELP_BOOK/Contents/Resources/en.lproj"
PLIST_BOOK_TITLE="$(/usr/libexec/PlistBuddy -c 'Print :HPDBookTitle' "$HELP_BOOK/Contents/Info.plist")"
if [ "$PLIST_BOOK_TITLE" != "$BOOK_NAME" ]; then
  echo "error: help book HPDBookTitle is '$PLIST_BOOK_TITLE', but the app asks for '$BOOK_NAME'" >&2
  exit 1
fi
if ! grep -qF "<meta name=\"AppleTitle\" content=\"$BOOK_NAME\">" "$HELP_LPROJ/index.html"; then
  echo "error: index.html has no AppleTitle matching '$BOOK_NAME'; the Help menu would open an empty window" >&2
  exit 1
fi

# A help index that predates a page still opens and still searches. It just
# returns wrong results, which is indistinguishable from a working book until
# someone searches for something added in the last build.
INDEX_FILE="$HELP_LPROJ/DDCC.cshelpindex"
if [ ! -f "$INDEX_FILE" ]; then
  echo "error: help index $INDEX_FILE is missing" >&2
  exit 1
fi
# Assigned before the test rather than substituted inside `if [ -n ... ]`:
# under `set -e`, a command substitution embedded in an `if` condition does
# not propagate a failure of the command being substituted, so a broken
# `find` here would be swallowed silently instead of aborting the build.
STALE_PAGE="$(find "$HELP_LPROJ" -name '*.html' -newer "$INDEX_FILE" -print -quit)"
if [ -n "$STALE_PAGE" ]; then
  echo "error: help index is older than $STALE_PAGE; it would search stale content" >&2
  exit 1
fi

# openHelpAnchor no-ops when the anchor is absent, so a missing one is a dead
# link the app cannot report. Compare what the catalogue declares against what
# the built HTML actually carries.
#
# Captured into a variable first, not read via process substitution
# (`< <(...)`): under `set -e`, a failing command inside `<(...)` does not
# abort the script, so a broken `swift run` would silently produce zero
# lines and the loop below would never run — approving everything by never
# checking anything. A plain `VAR="$(...)"` assignment IS subject to
# `set -e`, so a real failure here still aborts the build. The explicit
# empty-output check below guards the remaining case: a command that exits
# 0 but happens to print nothing.
ANCHOR_LIST="$(swift run -c release HelpBookBuilder --list-anchors)"
if [ -z "$ANCHOR_LIST" ]; then
  echo "error: --list-anchors produced no anchors; this check would have silently passed" >&2
  exit 1
fi
MISSING_ANCHORS=0
ANCHOR_COUNT=0
while IFS= read -r anchor; do
  ANCHOR_COUNT=$((ANCHOR_COUNT + 1))
  if ! grep -qrF "<a name=\"$anchor\"></a>" "$HELP_LPROJ"; then
    echo "error: anchor '$anchor' is declared in the catalogue but absent from the built book" >&2
    MISSING_ANCHORS=1
  fi
done <<< "$ANCHOR_LIST"
if [ "$ANCHOR_COUNT" -eq 0 ]; then
  echo "error: anchor check examined zero anchors; this check would have silently passed" >&2
  exit 1
fi
if [ "$MISSING_ANCHORS" != "0" ]; then
  exit 1
fi

SIGNED_ID="$(codesign -dv "$APP" 2>&1 | awk -F= '/^Identifier=/ {print $2}')"
if [ "$SIGNED_ID" != "$BUNDLE_ID" ]; then
  echo "error: signed identifier is '$SIGNED_ID', expected '$BUNDLE_ID'" >&2
  exit 1
fi

# When a named identity was requested, confirm that is what actually signed.
# The guard above matches substrings (as codesign itself does), so a leftover
# certificate with an overlapping common name could satisfy both and sign with
# the wrong key. This checks the result rather than the intent.
if [ "$IDENTITY" != "-" ]; then
  # `!seen++` rather than `exit`: awk exiting early closes the pipe, codesign
  # dies on SIGPIPE, and pipefail turns that into exit 141 which set -e treats
  # as a silent abort. Measured 2026-08-12 — the script signed, then vanished
  # without installing or printing anything.
  AUTHORITY="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !seen++ {print $2}')"
  if [ "$AUTHORITY" != "$IDENTITY" ]; then
    echo "error: signed by '$AUTHORITY', expected '$IDENTITY'" >&2
    exit 1
  fi
fi

if [ "$RELEASE" = "1" ]; then
  # Deliberately last: every check above can reject this bundle, and each one
  # is cheaper than an Apple round trip. Notarizing first would spend minutes
  # to learn what a PlistBuddy read already knew.
  #
  # notarytool takes a container, never a bundle -- handed DDCC.app directly it
  # answers "The path could not be read", which reads like a permissions fault
  # rather than a wrong argument. ditto is what Apple documents for making one;
  # plain zip does not preserve the symlinks inside a bundle, and what arrives
  # then fails to validate as signed.
  ZIP="$APP.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  ddcc_notarize_container "$ZIP"
  rm -f "$ZIP"

  # The ticket is stapled to the bundle, not to the zip that was submitted --
  # the zip was only a shipping carton and is already gone. Stapling the app
  # is what makes the copy inside the disk image work offline.
  ddcc_staple "$APP"

  # Reports source=Notarized Developer ID once the ticket is attached. Worth
  # printing, but not proof: this machine holds the signing key and trusts the
  # certificate by construction. Only a Mac that has never seen the key can
  # tell you what a visitor will see.
  spctl --assess --type exec -vv "$APP"
fi

echo "built $APP  (id $BUNDLE_ID, identity $IDENTITY)"

if [ "$INSTALL" = "1" ]; then
  # Matches on the executable name, which is the same in the pre-rename bundle
  # and this one, so a copy running from the old DevDriveCacheClean.app is
  # caught too. Overwriting a running bundle corrupts the running process.
  if pgrep -f "/Applications/.*\.app/Contents/MacOS/DevDriveCacheClean" >/dev/null 2>&1; then
    echo "error: an installed copy is running from /Applications. Quit it and retry." >&2
    exit 1
  fi

  # One-time migration from the pre-rename name. Left in place it would sit in
  # /Applications as a stale second copy with the same bundle id, and which one
  # LaunchServices resolves for that id is then arbitrary.
  LEGACY="/Applications/DevDriveCacheClean.app"
  if [ -d "$LEGACY" ] && [ "$LEGACY" != "/Applications/$APP" ]; then
    rm -rf "$LEGACY"
    echo "removed legacy $LEGACY"
  fi
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "installed /Applications/$APP"
fi
