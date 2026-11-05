#!/bin/bash
# Build MacAIMagic.app: the SwiftUI app + the engine binaries + the download script, ad-hoc signed.
# Output: dist/MacAIMagic.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/MacAIMagic.app"

cd "$ROOT/App"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MacAIMagic"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/MacAIMagic"
cp "$ROOT/tools/download_model.sh" "$ROOT/tools/models.json" "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

if [ -x "$ROOT/engine/bin/image-engine" ]; then
  cp "$ROOT/engine/bin/image-engine" "$APP/Contents/Resources/engine/"
else
  echo "let op: engine/bin/image-engine ontbreekt; draai scripts/build_image_engine.sh, anders werkt de pagina Beeld niet"
fi

if [ -x "$ROOT/engine/bin/llama-server" ]; then
  cp "$ROOT"/engine/bin/llama-* "$ROOT"/engine/bin/ggml-rpc-server "$APP/Contents/Resources/engine/"
else
  echo "let op: engine/bin/llama-server ontbreekt; draai eerst scripts/build_engine.sh"
fi

ICONSET="$ROOT/dist/AppIcon.iconset"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacAIMagic</string>
  <key>CFBundleDisplayName</key><string>MacAIMagic</string>
  <key>CFBundleIdentifier</key><string>app.fremen.macaimagic</string>
  <key>CFBundleExecutable</key><string>MacAIMagic</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.9.11</string>
  <key>CFBundleVersion</key><string>36</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>MacAIMagic bewaart de concepten en documenten van een project in de map die je kiest.</string>
  <key>NSPicturesFolderUsageDescription</key><string>MacAIMagic bewaart de afbeeldingen die je maakt in Afbeeldingen/MacAIMagic.</string>
  <key>NSAppleEventsUsageDescription</key><string>MacAIMagic vraagt je wachtwoord om de GPU-geheugenlimiet te verhogen.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Signing: with a Developer ID certificate when this Mac has one (or SIGN_ID names it), otherwise ad hoc.
# Hardened runtime on every binary, as notarization requires; inner binaries first, the app last.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$SIGN_ID" ]; then SIGN=(--sign "$SIGN_ID" --timestamp); else SIGN=(--sign -); fi
for b in "$APP"/Contents/Resources/engine/*; do codesign --force --options runtime "${SIGN[@]}" "$b"; done
codesign --force --options runtime --entitlements "$ROOT/scripts/MacAIMagic.entitlements" "${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"
echo "ondertekend: ${SIGN_ID:-ad hoc}"

# Notarization by Apple, when signed with Developer ID and the credentials are stored
# (once: xcrun notarytool store-credentials macaimagic --apple-id … --team-id … --password <app-specific password>)
NOTARY_PROFILE="${NOTARY_PROFILE:-macaimagic}"
if [ -n "$SIGN_ID" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  ZIP="$ROOT/dist/MacAIMagic-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  spctl --assess --type execute -vv "$APP"
elif [ -n "$SIGN_ID" ]; then
  echo "let op: niet genotariseerd, er zijn geen notarytool-gegevens onder '$NOTARY_PROFILE'"
fi
echo "klaar: $APP"
