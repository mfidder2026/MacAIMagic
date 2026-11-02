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
  <key>CFBundleShortVersionString</key><string>1.6.1</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MacAIMagic vraagt je wachtwoord om de GPU-geheugenlimiet te verhogen.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "klaar: $APP"
