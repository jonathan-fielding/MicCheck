#!/bin/zsh
# Packs files into a compressed disk image, then signs, notarizes and staples it.
#
#   Tools/make-dmg.sh <out.dmg> <volume name> <sign identity> <notary profile> <file>... [--applications]
#
# --applications adds an /Applications shortcut, for drag-to-install app images.
# The identity is a "Developer ID Application" one; the notary profile comes from
# `xcrun notarytool store-credentials`.
set -euo pipefail

OUT=$1 VOLNAME=$2 IDENTITY=$3 PROFILE=$4
shift 4

STAGE=$(mktemp -d -t micdeck-dmg)
trap 'rm -rf "$STAGE"' EXIT
for f in "$@"; do
    if [[ $f == --applications ]]; then
        ln -s /Applications "$STAGE/Applications"
    else
        cp -R "$f" "$STAGE/"
    fi
done

rm -f "$OUT"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
codesign --force --timestamp --sign "$IDENTITY" "$OUT"
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT"
spctl --assess --type open --context context:primary-signature --verbose "$OUT"
