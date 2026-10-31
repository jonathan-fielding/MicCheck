#!/bin/zsh
# Builds the MicDeck Audio driver (Driver/) and its installer into ./dist
#
#   ./build-driver.sh              local build: universal, ad-hoc signed, unsigned dist/MicDeckAudio.pkg
#   ./build-driver.sh --install    local build, then installs it (asks for your password)
#   ./build-driver.sh --release    Developer ID signed and notarized dist/MicDeckAudio.pkg,
#                                  plus dist/MicDeckAudio.dmg (pkg + uninstall.sh) for GitHub releases
#
# The driver can't ship inside the Mac App Store app (a sandboxed app can't install into
# /Library/Audio/Plug-Ins/HAL), so it's a separate download that MicDeck links to.
#
# --release needs:
#   DRIVER_SIGN_IDENTITY     e.g. "Developer ID Application: Jonathan Fielding (TEAMID)"
#   INSTALLER_SIGN_IDENTITY  e.g. "Developer ID Installer: Jonathan Fielding (TEAMID)"
#   NOTARY_PROFILE           a keychain profile made with `xcrun notarytool store-credentials`
# Both modes take MARKETING_VERSION (default 1.0.0) and BUILD_NUMBER (default: commit count).
set -euo pipefail
cd "$(dirname "$0")"

MODE=dev
[[ "${1:-}" == "--release" ]] && MODE=release
[[ "${1:-}" == "--install" ]] && MODE=install

MARKETING_VERSION=${MARKETING_VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
BUNDLE=dist/driver-root/MicDeckAudio.driver

rm -rf dist/driver-root
mkdir -p "$BUNDLE/Contents/MacOS"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -bundle -O2 -Wall -Wextra -Werror \
    -framework CoreAudio -framework CoreFoundation \
    -o "$BUNDLE/Contents/MacOS/MicDeckAudio" Driver/MicDeckAudio.c
cp Driver/Info.plist "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"

PKG=dist/MicDeckAudio.pkg
rm -f "$PKG"
chmod +x Driver/scripts/postinstall
PKG_ARGS=(--root dist/driver-root --install-location /Library/Audio/Plug-Ins/HAL --scripts Driver/scripts
          --identifier com.jonathanfielding.micdeck.audio --version "$MARKETING_VERSION")

if [[ $MODE == release ]]; then
    : "${DRIVER_SIGN_IDENTITY:?set DRIVER_SIGN_IDENTITY to your Developer ID Application identity}"
    : "${INSTALLER_SIGN_IDENTITY:?set INSTALLER_SIGN_IDENTITY to your Developer ID Installer identity}"
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
    codesign --force --timestamp --options runtime --sign "$DRIVER_SIGN_IDENTITY" "$BUNDLE"
    pkgbuild $PKG_ARGS --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    # The download: the installer plus the uninstaller, in one notarized disk image.
    Tools/make-dmg.sh dist/MicDeckAudio.dmg "MicDeck Audio" "$DRIVER_SIGN_IDENTITY" "$NOTARY_PROFILE" \
        "$PKG" Driver/uninstall.sh
    echo "Built: $PKG and dist/MicDeckAudio.dmg ($MARKETING_VERSION build $BUILD_NUMBER), signed and notarized."
    exit 0
fi

codesign --force --sign - "$BUNDLE"
pkgbuild $PKG_ARGS "$PKG"
echo "Built: $PKG ($MARKETING_VERSION build $BUILD_NUMBER), ad-hoc signed (local use only)."

if [[ $MODE == install ]]; then
    sudo installer -pkg "$PKG" -target /
    echo "Installed. \"MicDeck Microphone\" should now appear in Sound settings."
fi
