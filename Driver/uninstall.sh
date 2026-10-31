#!/bin/sh
# Removes the MicDeck Audio driver. Run with: sudo ./uninstall.sh
set -e
rm -rf /Library/Audio/Plug-Ins/HAL/MicDeckAudio.driver
pkgutil --forget com.jonathanfielding.micdeck.audio >/dev/null 2>&1 || true
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "MicDeck Audio driver removed."
