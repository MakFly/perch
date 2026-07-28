#!/usr/bin/env bash
# Assembles Perch.app from the SwiftPM build products.
#
# SwiftPM cannot emit an app bundle, and a .xcodeproj would mean the whole project can no
# longer be driven from a terminal. So we build executables and lay out the bundle here.
set -euo pipefail

CONFIG="${1:-debug}"
MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$MAC_DIR/build"
APP="$BUILD_DIR/Perch.app"

# A release build is universal; a debug build is not.
#
# Both architectures matter for exactly one artifact — the DMG — and building two of
# everything doubles the edit-run loop that this script exists to keep short. So `release`
# gets `--arch arm64 --arch x86_64`, which SwiftPM lipos itself, and `debug` stays native.
# Shipping an arm64-only bundle does not degrade on an Intel Mac: it refuses to launch.
# Expanded as ${ARCHS[@]+"${ARCHS[@]}"} everywhere below: under `set -u`, bash 3.2 —
# which is what macOS ships — treats an empty array expansion as an unbound variable, so
# the plain form breaks every debug build the moment this array is empty.
ARCHS=()
if [ "$CONFIG" = "release" ]; then
  ARCHS=(--arch arm64 --arch x86_64)
fi

cd "$MAC_DIR"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product PerchApp
# The hook runs wherever the CLI runs, which is the same Mac — but it is copied into the
# bundle, so it has to be as universal as the app around it or a signed bundle contains a
# binary half its machines cannot execute.
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product perch-hook

BIN_DIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/PerchApp" "$APP/Contents/MacOS/Perch"
# The hook binary ships inside the bundle so a single .app is the whole install.
cp "$BIN_DIR/perch-hook" "$APP/Contents/Resources/perch-hook"

# Localisations go straight into Contents/Resources — the classic layout, which is what
# `Bundle.main` looks for and what keeps working without a .xcodeproj.
for lproj in "$MAC_DIR"/Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# Departure Mono, registered by `ATSApplicationFontsPath` below. Bundled rather than
# assumed installed: the panel's whole look is that font, and a machine that does not have
# it must not silently fall back to SF Mono.
cp -R "$MAC_DIR/Resources/Fonts" "$APP/Contents/Resources/"

# The icon, drawn by Scripts/make-icon.swift and committed rather than generated here: the
# build should not need AppKit to draw a picture, and the .icns changes about once a year.
cp "$MAC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Agent sprites, if anyone drops some in. Optional by construction: with this directory
# absent — which is how the repository ships — AgentGlyph draws its own pixel art and
# nothing else changes.
if [ -d "$MAC_DIR/Resources/Sprites" ]; then
  cp -R "$MAC_DIR/Resources/Sprites" "$APP/Contents/Resources/"
fi

# The scripts that wire Perch into the CLIs, carried inside the bundle so a copy dragged
# out of the DMG is a complete install: the onboarding runs these, and `uninstall.sh` is
# documented as shipping with the app. Only the user-facing ones — `release.sh`,
# `remove.sh`, `setup.sh` and `appcast-keys.sh` need a clone and a Postgres container, and
# an app that carries a script it cannot run is offering something that will fail.
mkdir -p "$APP/Contents/Resources/scripts"
for script in lib.sh install-hooks.sh install-extension.sh configure-kitty.sh \
  usage-bridge.sh remote.sh uninstall.sh; do
  cp "$MAC_DIR/../../scripts/$script" "$APP/Contents/Resources/scripts/"
done

# The public half of the appcast key, baked in so the app can verify an update before it
# ever looks at the version. Absent until ./scripts/appcast-keys.sh has been run, in which
# case update checking simply stays off — an app that cannot verify must not update.
APPCAST_KEY=""
if [ -f "$HOME/.perch/appcast-key" ]; then
  # apps/mac/../.. — the scripts live at the repo root, not beside the app.
  APPCAST_KEY="$("$MAC_DIR/../../scripts/appcast-keys.sh" --show 2>/dev/null | tail -1 || true)"
fi

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Perch</string>
    <key>CFBundleDisplayName</key>
    <string>Perch</string>
    <key>CFBundleIdentifier</key>
    <string>tech.kweli.perch</string>
    <key>CFBundleExecutable</key>
    <string>Perch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <!-- Registers everything in Contents/Resources/Fonts for this process only, so
         installing Perch never adds a font to the user's machine. -->
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>fr</string>
    </array>
    <!-- No Dock icon, no menu bar item: Perch lives in the notch. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Jumping to the session you clicked means driving the terminal that runs it.
         macOS shows this string the first time Perch asks. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Perch needs to control your terminal to bring the session you clicked to the front.</string>
</dict>
</plist>
PLIST

# The version is hardcoded above so a plain `make-app.sh` needs no arguments, and
# overridable here so a tagged CI build produces a bundle that says what it is. A DMG named
# 0.2.0 containing an app that reports 0.1.0 is the kind of mismatch the updater compares
# against and gets wrong.
if [ -n "${PERCH_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PERCH_VERSION" \
    "$APP/Contents/Info.plist" >/dev/null
fi
if [ -n "${PERCH_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PERCH_BUILD" \
    "$APP/Contents/Info.plist" >/dev/null
fi

if [ -n "$APPCAST_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $APPCAST_KEY" \
    "$APP/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c \
    "Add :SUFeedURL string ${PERCH_FEED_URL:-https://example.invalid/appcast.xml}" \
    "$APP/Contents/Info.plist" >/dev/null
fi

# Automation is entitled explicitly; without it the first AppleEvent fails outright rather
# than prompting.
cat >"$BUILD_DIR/perch.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Ad-hoc signature keeps macOS from killing the app on launch. Developer ID signing and
# notarisation are deliberately out of scope for v1.
codesign --force --sign - --timestamp=none \
  --entitlements "$BUILD_DIR/perch.entitlements" "$APP" >/dev/null 2>&1 || true

echo "built $APP"
