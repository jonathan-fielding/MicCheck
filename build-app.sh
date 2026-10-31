#!/bin/zsh
# Builds "MicDeck.app" and the ngmic CLI into ./dist
#
#   ./build-app.sh              local build: native arch, ad-hoc signed, sandboxed
#   ./build-app.sh --appstore   Mac App Store build: universal, distribution-signed, dist/MicDeck.pkg
#   ./build-app.sh --dmg        direct download: universal, Developer ID signed, notarized dist/MicDeck.dmg
#
# --dmg needs:
#   DEVELOPER_ID_IDENTITY    e.g. "Developer ID Application: Jonathan Fielding (TEAMID)"
#   NOTARY_PROFILE           a keychain profile made with `xcrun notarytool store-credentials`
#
# --appstore needs:
#   TEAM_ID                  your 10-character Apple Developer Team ID
#   PROVISIONING_PROFILE     path to the Mac App Store provisioning profile for com.jonathanfielding.micdeck
# and optionally:
#   APP_SIGN_IDENTITY        default "Apple Distribution"
#   INSTALLER_SIGN_IDENTITY  default "3rd Party Mac Developer Installer"
#
# Both modes take MARKETING_VERSION (default 1.0.0) and BUILD_NUMBER (default: commit count),
# and DRIVER_DOWNLOAD_URL: the page where users get the MicDeck Audio driver (see build-driver.sh).
set -euo pipefail
cd "$(dirname "$0")"

MODE=dev
[[ "${1:-}" == "--appstore" ]] && MODE=appstore
[[ "${1:-}" == "--dmg" ]] && MODE=dmg

BUNDLE_ID=com.jonathanfielding.micdeck
MARKETING_VERSION=${MARKETING_VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}

if [[ $MODE == appstore ]]; then
    : "${TEAM_ID:?set TEAM_ID to your Apple Developer Team ID}"
    : "${PROVISIONING_PROFILE:?set PROVISIONING_PROFILE to the Mac App Store .provisionprofile}"
    [[ -f "$PROVISIONING_PROFILE" ]] || { echo "No such file: $PROVISIONING_PROFILE" >&2; exit 1; }
    APP_SIGN_IDENTITY=${APP_SIGN_IDENTITY:-Apple Distribution}
    INSTALLER_SIGN_IDENTITY=${INSTALLER_SIGN_IDENTITY:-3rd Party Mac Developer Installer}
    ARCH_FLAGS=(--arch arm64 --arch x86_64)   # macOS 15 still runs on Intel Macs
elif [[ $MODE == dmg ]]; then
    : "${DEVELOPER_ID_IDENTITY:?set DEVELOPER_ID_IDENTITY to your Developer ID Application identity}"
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
    ARCH_FLAGS=()
fi

swift build -c release $ARCH_FLAGS --product MicDeck
swift build -c release $ARCH_FLAGS --product ngmic
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

APP="dist/MicDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Resources/AppIcon.icns ] || { swift Tools/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns; }
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
cp "$BIN/MicDeck" "$APP/Contents/MacOS/MicDeck"
cp "$BIN/ngmic" dist/ngmic

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
# Where "Optimise voice" sends people to get the MicDeck Audio driver (./build-driver.sh --release).
# Without it, the install step shows build instructions instead of a download button.
if [[ -n "${DRIVER_DOWNLOAD_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :MicDeckAudioDriverURL string $DRIVER_DOWNLOAD_URL" "$PLIST"
fi

if [[ $MODE == dev ]]; then
    # Hardened runtime: no DYLD_* injection into a process that holds the Microphone grant.
    codesign --force --sign - --options runtime --entitlements Resources/MicDeck.entitlements "$APP"
    codesign --force --sign - --options runtime dist/ngmic
    echo "Built: $APP ($MARKETING_VERSION build $BUILD_NUMBER) and dist/ngmic"
    exit 0
fi

if [[ $MODE == dmg ]]; then
    # Same sandboxed entitlements as the store build; Developer ID apps don't embed a profile.
    codesign --force --timestamp --options runtime --entitlements Resources/MicDeck.entitlements \
        --sign "$DEVELOPER_ID_IDENTITY" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    Tools/make-dmg.sh dist/MicDeck.dmg "MicDeck" "$DEVELOPER_ID_IDENTITY" "$NOTARY_PROFILE" "$APP" --applications
    echo "Built: dist/MicDeck.dmg ($MARKETING_VERSION build $BUILD_NUMBER), signed and notarized."
    exit 0
fi

# Store signing: the profile is embedded and the entitlements must name the same app ID and team.
cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
ENTITLEMENTS=$(mktemp -t micdeck-entitlements).plist
cp Resources/MicDeck.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"

codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_SIGN_IDENTITY" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --strict --deep --verbose=2 "$APP"

PKG=dist/MicDeck.pkg
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
echo "Built: $PKG ($MARKETING_VERSION build $BUILD_NUMBER). Upload it with Transporter or 'xcrun altool --upload-package'."
