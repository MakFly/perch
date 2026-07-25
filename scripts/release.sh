#!/usr/bin/env bash
# Builds, signs, notarises and packages Perch.
#
#   ./scripts/release.sh                 # what it would do, and what is missing
#   ./scripts/release.sh --build         # release build + DMG, ad-hoc signed
#   ./scripts/release.sh --sign          # …signed with your Developer ID
#   ./scripts/release.sh --notarize      # …submitted to Apple and stapled
#
# Everything that needs a secret reads it from the environment, so this file can be
# committed and nothing here has to be edited to ship:
#
#   PERCH_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   PERCH_NOTARY_PROFILE  a keychain profile made with `xcrun notarytool store-credentials`
#   PERCH_SPARKLE_KEY     path to the EdDSA private key, for signing the appcast
#
# Without them the build still runs and still produces a DMG — it is just ad-hoc signed,
# which works on your own Mac and nowhere else. That distinction is stated rather than
# hidden, because an unsigned build that looks signed is how you find out at the worst
# possible moment.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${1:---check}"
DIST="$PERCH_ROOT/dist"
APP="$PERCH_ROOT/apps/mac/build/Perch.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
DMG="$DIST/Perch-$VERSION.dmg"

check() {
  info "version        $VERSION"
  if [ -n "${PERCH_SIGN_IDENTITY:-}" ]; then
    ok "signing        $PERCH_SIGN_IDENTITY"
  else
    warn "signing        PERCH_SIGN_IDENTITY not set — builds will be ad-hoc signed"
    info "               list yours with: security find-identity -v -p codesigning"
  fi
  if [ -n "${PERCH_NOTARY_PROFILE:-}" ]; then
    ok "notarisation   profile $PERCH_NOTARY_PROFILE"
  else
    warn "notarisation   PERCH_NOTARY_PROFILE not set"
    info "               create one with: xcrun notarytool store-credentials"
  fi
  local key="${PERCH_SPARKLE_KEY:-$PERCH_HOME/appcast-key}"
  if [ -f "$key" ]; then
    ok "appcast        signed with $key"
  else
    warn "appcast        no signing key — run ./scripts/appcast-keys.sh"
  fi
  echo
  info "run with --build, --sign or --notarize"
}

build() {
  info "building release…"
  "$PERCH_ROOT/apps/mac/Scripts/make-app.sh" release >/dev/null
  ok "built $APP"
}

sign() {
  [ -n "${PERCH_SIGN_IDENTITY:-}" ] || fail "PERCH_SIGN_IDENTITY is not set"
  local entitlements="$PERCH_ROOT/apps/mac/build/perch.entitlements"

  # The hook binary is a separate executable inside the bundle and has to be signed
  # before the bundle that contains it, or the outer signature seals a stale inner one.
  codesign --force --options runtime --timestamp \
    --sign "$PERCH_SIGN_IDENTITY" "$APP/Contents/Resources/perch-hook"
  codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" \
    --sign "$PERCH_SIGN_IDENTITY" "$APP"

  codesign --verify --deep --strict --verbose=2 "$APP"
  ok "signed and verified"
}

package() {
  mkdir -p "$DIST"
  rm -f "$DMG"
  local staging
  staging="$(mktemp -d)"
  cp -R "$APP" "$staging/"
  ln -s /Applications "$staging/Applications"

  hdiutil create -volname "Perch" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$staging"
  ok "packaged $DMG"
}

notarize() {
  [ -n "${PERCH_NOTARY_PROFILE:-}" ] || fail "PERCH_NOTARY_PROFILE is not set"
  info "submitting to Apple — this takes a few minutes…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PERCH_NOTARY_PROFILE" --wait
  # Stapling is what lets the DMG open on a Mac that is offline.
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  ok "notarised and stapled"
}

appcast() {
  local key="${PERCH_SPARKLE_KEY:-$PERCH_HOME/appcast-key}"
  [ -f "$key" ] || {
    warn "skipping appcast — no signing key. Run ./scripts/appcast-keys.sh"
    return 0
  }

  # Signed with our own tool rather than Sparkle's `sign_update`, which is not on most
  # machines. Same scheme (Ed25519 over the raw bytes), so the output is interchangeable.
  local signature
  signature="$(PERCH_SPARKLE_KEY="$key" "$PERCH_ROOT/scripts/appcast-keys.sh" --sign "$DMG")"

  mkdir -p "$DIST"
  cat >"$DIST/appcast-entry.xml" <<XML
<item>
  <title>$VERSION</title>
  <sparkle:version>$VERSION</sparkle:version>
  <enclosure url="${PERCH_DOWNLOAD_BASE:-https://example.invalid}/Perch-$VERSION.dmg"
             length="$(stat -f%z "$DMG")"
             type="application/octet-stream"
             sparkle:edSignature="$signature" />
</item>
XML
  ok "appcast entry written to $DIST/appcast-entry.xml"
  [ -n "${PERCH_DOWNLOAD_BASE:-}" ] || \
    warn "set PERCH_DOWNLOAD_BASE to where you host the DMG before publishing the feed"
}

case "$MODE" in
  --check) check ;;
  --build) build; package; appcast ;;
  --sign) build; sign; package; appcast ;;
  --notarize) build; sign; package; notarize; appcast ;;
  *) fail "usage: release.sh [--check|--build|--sign|--notarize]" ;;
esac
