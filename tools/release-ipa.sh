#!/bin/bash
# Build a RELEASE YTLite and splice it into an already-cyan-patched IPA, replacing only
# YTLite.dylib. The release sibling of tools/flagdbg-ipa.sh: far faster than re-running cyan
# (no submodule tweak rebuilds) and every other injected tweak stays byte-identical, so the
# only thing that changed between the old IPA and the new one is our dylib.
#
#   tools/release-ipa.sh <patched-input.ipa> [output.ipa]
#
# The input must be a patched IPA that already carries the other tweaks AND the libreyt://
# CFBundleURLTypes entry (AGENTS.md §4) -- this script does not re-add either.
#
# cyan rewrites the tweak's CydiaSubstrate dependency to @rpath; a fresh Theos build still points
# at /Library/Frameworks, so we redo that one rewrite here. Signatures are invalidated on purpose
# -- Sideloadly (or resign.sh) re-signs the result.
set -euo pipefail
IN="${1:?usage: tools/release-ipa.sh <patched.ipa> [out.ipa]}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VER=$(awk -F'= *' '/^PACKAGE_VERSION/{print $2}' "$REPO/Makefile")
OUT="${2:-${IN%.ipa}_v${VER}.ipa}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

cd "$REPO"
make clean package DEBUG=0 FINALPACKAGE=1 >/dev/null
DEB=$(ls -t packages/com.dvntm.ytlite_*.deb | head -1)
echo "==> built $DEB (version $VER)"

MEMBER=$(ar t "$DEB" | grep '^data.tar')
case "$MEMBER" in
  *.xz)   ar p "$DEB" "$MEMBER" | tar xJ -C "$WORK" ;;
  *.gz)   ar p "$DEB" "$MEMBER" | tar xz -C "$WORK" ;;
  *.lzma) ar p "$DEB" "$MEMBER" | tar --lzma -x -C "$WORK" ;;
  *)      ar p "$DEB" "$MEMBER" | tar x  -C "$WORK" ;;
esac
DYLIB="$WORK/Library/MobileSubstrate/DynamicLibraries/YTLite.dylib"
[ -f "$DYLIB" ] || { echo "!! no YTLite.dylib in $DEB"; exit 1; }

# A release dylib must carry NO diagnostic markers. This is the inverse of the flagdbg script's
# check and it is the one that matters: shipping a FLAG_DEBUG dylib by accident is silent.
#
# Count into a variable instead of piping into `grep -q`. Under `set -o pipefail` a successful
# `grep -q` exits immediately, `strings` dies of SIGPIPE, and the PIPELINE reports 141 -- so
# `if strings ... | grep -q MARKER` is FALSE exactly when the marker IS present, and a debug
# dylib would sail through this gate as clean. Same trap in either direction; don't reintroduce it.
marks=$(strings -a "$DYLIB" | grep -cE 'YTLITE|FLAGRISK' || true)
if [ "$marks" -ne 0 ]; then
  echo "!! dylib carries $marks debug markers -- refusing to build a release IPA"; exit 1
fi
vhits=$(strings -a "$DYLIB" | grep -cxF "$VER" || true)
[ "$vhits" -ne 0 ] || echo "   (note: version string $VER not found in dylib)"

install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
                          @rpath/CydiaSubstrate.framework/CydiaSubstrate "$DYLIB" 2>/dev/null

# zip APPENDS to an existing archive -- an old output would keep its stale dylib alongside the
# new one and iOS would load whichever it found first. Always start from a fresh copy.
rm -f "$OUT"
cp "$IN" "$OUT"
# Resolve to an ABSOLUTE path before the cd below: zip runs from the staging dir, so a relative
# archive path would silently create a brand-new zip in there instead of updating ours.
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
mkdir -p "$WORK/stage/Payload/YouTube.app/Frameworks"
cp "$DYLIB" "$WORK/stage/Payload/YouTube.app/Frameworks/YTLite.dylib"
( cd "$WORK/stage" && zip -q "$OUT_ABS" "Payload/YouTube.app/Frameworks/YTLite.dylib" )

# Prove the swap landed, and that what landed is genuinely a release build.
unzip -p "$OUT_ABS" "Payload/YouTube.app/Frameworks/YTLite.dylib" > "$WORK/verify.dylib"
vmarks=$(strings -a "$WORK/verify.dylib" | grep -cE 'YTLITE|FLAGRISK' || true)
[ "$vmarks" -eq 0 ] || { echo "!! spliced dylib has $vmarks debug markers"; exit 1; }
cmp -s "$DYLIB" "$WORK/verify.dylib" || { echo "!! swap did not land in $OUT"; exit 1; }

# The libreyt:// scheme must survive, or open-in-app silently stops working (AGENTS.md §4).
unzip -p "$OUT_ABS" "Payload/YouTube.app/Info.plist" > "$WORK/i.plist"
urlhits=$(plutil -extract CFBundleURLTypes json -o - "$WORK/i.plist" | grep -c libreyt || true)
[ "$urlhits" -ne 0 ] \
  || echo "!! WARNING: libreyt:// scheme missing from Info.plist -- open-in-app will not work"

echo "==> wrote $OUT ($(du -h "$OUT_ABS" | cut -f1), release dylib verified, 0 debug markers)"
