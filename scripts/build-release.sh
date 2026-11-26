#!/usr/bin/env bash
#
# Builds GlucoseBar.app for direct download and packages it as GlucoseBar.zip
# and GlucoseBar.dmg, plus a SHA256SUMS.txt.
#
# Used by .github/workflows/release.yml, and can be run locally:
#
#   VERSION=1.4.1 scripts/build-release.sh
#
# Environment:
#   VERSION            Required. Version to stamp into the app, e.g. 1.4.1 or
#                      1.4.1-rc1 (the suffix stays out of the bundle version).
#   OUTPUT_DIR         Where the packages go. Defaults to ./dist.
#
#   Developer ID signing (without TEAM_ID the app is ad-hoc signed):
#   TEAM_ID            Apple Developer team ID.
#   SIGNING_IDENTITY   Defaults to "Developer ID Application".
#   KEYCHAIN           Keychain that holds the certificate, if not the default.
#
#   Notarization (only with Developer ID signing; skipped when unset):
#   NOTARY_KEY_PATH    Path to an App Store Connect API key (.p8).
#   NOTARY_KEY_ID      The key's ID.
#   NOTARY_ISSUER_ID   The key's issuer ID.

set -euo pipefail

APP_NAME=GlucoseBar
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

: "${VERSION:?Set VERSION, e.g. VERSION=1.4.1}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.]+)?$ ]]; then
  echo "error: VERSION '$VERSION' should look like 1.4.1 or 1.4.1-rc1" >&2
  exit 1
fi
# CFBundleShortVersionString has to be numeric.
MARKETING_VERSION="${VERSION%%-*}"

KEYCHAIN_ARGS=()
if [[ -n "${KEYCHAIN:-}" ]]; then
  KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi

if [[ -n "${TEAM_ID:-}" ]]; then
  IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
  SIGN_SETTINGS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$IDENTITY"
    "DEVELOPMENT_TEAM=$TEAM_ID"
    "OTHER_CODE_SIGN_FLAGS=--timestamp ${KEYCHAIN_ARGS[*]-}"
  )
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    NOTARIZE=true
  else
    NOTARIZE=false
  fi
else
  IDENTITY="-"
  SIGN_SETTINGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=-" DEVELOPMENT_TEAM=)
  NOTARIZE=false
fi

echo "==> Building $APP_NAME $VERSION (bundle version $MARKETING_VERSION)"
echo "    signing: $([[ $IDENTITY == - ]] && echo ad-hoc || echo "$IDENTITY")"
echo "    notarize: $NOTARIZE"

ARCHIVE="$WORK_DIR/$APP_NAME.xcarchive"
xcodebuild_cmd=(
  xcodebuild archive
  -project "$ROOT/$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE"
  -disableAutomaticPackageResolution
  "MARKETING_VERSION=$MARKETING_VERSION"
  "${SIGN_SETTINGS[@]}"
)
if command -v xcbeautify >/dev/null; then
  "${xcodebuild_cmd[@]}" | xcbeautify --quieter
else
  "${xcodebuild_cmd[@]}" -quiet
fi

STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"
ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$STAGE/$APP_NAME.app"
APP="$STAGE/$APP_NAME.app"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# notarize <file to submit> <file to staple the ticket to>
notarize() {
  local submit="$1" target="$2" result status id
  local auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  echo "==> Notarizing $(basename "$target")"
  result="$(xcrun notarytool submit "$submit" "${auth[@]}" --wait --timeout 30m --output-format json)" || true
  status="$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "$result" >&2
    id="$(jq -r '.id // empty' <<<"$result" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    fi
    echo "error: notarization of $(basename "$target") ended with status '${status:-unknown}'" >&2
    exit 1
  fi
  xcrun stapler staple "$target"
}

if [[ "$NOTARIZE" == true ]]; then
  # notarytool takes a zip, but the ticket gets stapled to the app inside it.
  ditto -c -k --keepParent "$APP" "$WORK_DIR/notarize.zip"
  notarize "$WORK_DIR/notarize.zip" "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$APP_NAME.zip" "$OUTPUT_DIR/$APP_NAME.dmg" "$OUTPUT_DIR/SHA256SUMS.txt"

echo "==> Packaging $APP_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$APP_NAME.zip"

echo "==> Packaging $APP_NAME.dmg"
DMG_ROOT="$WORK_DIR/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
# hdiutil occasionally fails with "Resource busy" on CI machines, so retry.
for attempt in 1 2 3; do
  if hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO \
      -ov "$OUTPUT_DIR/$APP_NAME.dmg"; then
    break
  fi
  if [[ $attempt == 3 ]]; then
    echo "error: hdiutil failed three times" >&2
    exit 1
  fi
  sleep 5
done

if [[ "$IDENTITY" != "-" ]]; then
  codesign --sign "$IDENTITY" --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$OUTPUT_DIR/$APP_NAME.dmg"
fi
if [[ "$NOTARIZE" == true ]]; then
  notarize "$OUTPUT_DIR/$APP_NAME.dmg" "$OUTPUT_DIR/$APP_NAME.dmg"
fi

(cd "$OUTPUT_DIR" && shasum -a 256 "$APP_NAME.zip" "$APP_NAME.dmg" > SHA256SUMS.txt)

echo "==> Done"
ls -lh "$OUTPUT_DIR"
