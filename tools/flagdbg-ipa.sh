#!/bin/bash
# Build a FLAG_DEBUG YTLite and splice it into an already-cyan-patched IPA, replacing only
# YTLite.dylib. Much faster than re-running cyan (no submodule tweak rebuilds) and it keeps every
# other injected tweak byte-identical to the build under test.
#
#   tools/flagdbg-ipa.sh <patched-input.ipa> [output.ipa]
#
# cyan rewrites the tweak's CydiaSubstrate dependency to @rpath; a fresh Theos build still points
# at /Library/Frameworks, so we redo that one rewrite here. Signatures are invalidated on purpose
# -- re-sign the result before installing.
set -euo pipefail
IN="${1:?usage: tools/flagdbg-ipa.sh <patched.ipa> [out.ipa]}"
OUT="${2:-${IN%.ipa}_flagdbg.ipa}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

cd "$REPO"
make clean package DEBUG=0 FINALPACKAGE=1 FLAG_DEBUG=1 >/dev/null
DEB=$(ls -t packages/com.dvntm.ytlite_*.deb | head -1)
echo "==> built $DEB"

MEMBER=$(ar t "$DEB" | grep '^data.tar')
case "$MEMBER" in
  *.xz)   ar p "$DEB" "$MEMBER" | tar xJ -C "$WORK" ;;
  *.gz)   ar p "$DEB" "$MEMBER" | tar xz -C "$WORK" ;;
  *.lzma) ar p "$DEB" "$MEMBER" | tar --lzma -x -C "$WORK" ;;
  *)      ar p "$DEB" "$MEMBER" | tar x  -C "$WORK" ;;
esac
DYLIB="$WORK/Library/MobileSubstrate/DynamicLibraries/YTLite.dylib"
[ -f "$DYLIB" ] || { echo "!! no YTLite.dylib in $DEB"; exit 1; }
grep -q FLAGRISK <(strings -a "$DYLIB") || { echo "!! built dylib has no FLAG_DEBUG markers"; exit 1; }

install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
                          @rpath/CydiaSubstrate.framework/CydiaSubstrate "$DYLIB" 2>/dev/null

cp "$IN" "$OUT"
# Resolve to an ABSOLUTE path before the cd below: zip runs from the staging dir, so a relative
# archive path would silently create a brand-new zip in there instead of updating ours.
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
mkdir -p "$WORK/stage/Payload/YouTube.app/Frameworks"
cp "$DYLIB" "$WORK/stage/Payload/YouTube.app/Frameworks/YTLite.dylib"
( cd "$WORK/stage" && zip -q "$OUT_ABS" "Payload/YouTube.app/Frameworks/YTLite.dylib" )

# Prove the swap actually landed -- this is exactly the failure mode the line above fixes.
unzip -p "$OUT_ABS" "Payload/YouTube.app/Frameworks/YTLite.dylib" > "$WORK/verify.dylib"
grep -q FLAGRISK <(strings -a "$WORK/verify.dylib") \
  || { echo "!! swap did not land in $OUT"; exit 1; }
echo "==> wrote $OUT (debug dylib verified in place)"
