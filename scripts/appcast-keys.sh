#!/usr/bin/env bash
# Generates the Ed25519 key pair that signs Perch's update feed.
#
#   ./scripts/appcast-keys.sh            # generate, once
#   ./scripts/appcast-keys.sh --show     # print the public key again
#   ./scripts/appcast-keys.sh --sign <file>
#
# This key is what stops anyone else from pushing an update to your users. The private
# half is written to ~/.perch/appcast-key with mode 600 and is never copied anywhere by
# any other script; the public half goes in the app bundle, in the open, where it belongs.
#
# Same scheme as Sparkle (Ed25519 over the raw file bytes), so a feed signed here is
# verifiable by Sparkle and by Perch's own checker.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEY="$PERCH_HOME/appcast-key"
TOOL="${TMPDIR:-/tmp}/perch-appcast-tool"

build_tool() {
  [ -x "$TOOL" ] && [ "$TOOL" -nt "${BASH_SOURCE[0]}" ] && return 0
  cat >"${TMPDIR:-/tmp}/perch-appcast-tool.swift" <<'SWIFT'
import CryptoKit
import Foundation

// CryptoKit rather than openssl: Ed25519 raw-key handling differs between openssl
// versions, and this has to produce exactly the 32 bytes Sparkle expects.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(2) }

switch arguments[1] {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    FileHandle.standardError.write(
        Data(key.publicKey.rawRepresentation.base64EncodedString().utf8))

case "public":
    guard arguments.count >= 3, let raw = Data(base64Encoded: arguments[2]),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { exit(1) }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count >= 4, let raw = Data(base64Encoded: arguments[2]),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
        let payload = FileManager.default.contents(atPath: arguments[3]),
        let signature = try? key.signature(for: payload)
    else { exit(1) }
    print(signature.base64EncodedString())

default:
    exit(2)
}
SWIFT
  swiftc -O "${TMPDIR:-/tmp}/perch-appcast-tool.swift" -o "$TOOL"
}

build_tool

case "${1:-generate}" in
  --show)
    [ -f "$KEY" ] || fail "no key yet — run ./scripts/appcast-keys.sh first"
    ok "public key (put this in Info.plist as SUPublicEDKey):"
    "$TOOL" public "$(cat "$KEY")"
    ;;

  --sign)
    [ -f "$KEY" ] || fail "no key yet — run ./scripts/appcast-keys.sh first"
    [ -f "${2:-}" ] || fail "usage: appcast-keys.sh --sign <file>"
    "$TOOL" sign "$(cat "$KEY")" "$2"
    ;;

  generate|"")
    if [ -f "$KEY" ]; then
      # Overwriting it would orphan every copy already installed: they verify against the
      # old public key and would reject every future update, permanently.
      fail "a key already exists at $KEY — refusing to overwrite it.
   Every installed copy verifies against its public half; replacing it would lock them
   out of updates for good. Delete it by hand only if nothing has shipped yet."
    fi
    mkdir -p "$PERCH_HOME"
    umask 077
    "$TOOL" generate >"$KEY" 2>"${TMPDIR:-/tmp}/perch-pub"
    chmod 600 "$KEY"
    ok "private key written to $KEY (mode 600) — back it up, it cannot be regenerated"
    ok "public key for Info.plist (SUPublicEDKey):"
    cat "${TMPDIR:-/tmp}/perch-pub"; echo
    rm -f "${TMPDIR:-/tmp}/perch-pub"
    info "then: export PERCH_SPARKLE_KEY=$KEY   and run ./scripts/release.sh --sign"
    ;;

  *) fail "usage: appcast-keys.sh [generate|--show|--sign <file>]" ;;
esac
