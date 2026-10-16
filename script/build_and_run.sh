#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="EarthPro"
CACHE_ROOT="$HOME/Library/Caches/EarthPro"
SWIFT_BUILD="$CACHE_ROOT/SwiftBuild"
BUNDLE="$CACHE_ROOT/BuildProducts/Earth Pro.app"
MODE="${1:-run}"
cd "$ROOT_DIR"
if pgrep -x "$APP_NAME" >/dev/null; then pkill -x "$APP_NAME"; fi
swift build --scratch-path "$SWIFT_BUILD"
BIN_DIR="$(swift build --scratch-path "$SWIFT_BUILD" --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
for resource in "$BIN_DIR"/*.bundle; do
    [[ -d "$resource" ]] && ditto "$resource" "$BUNDLE/Contents/Resources/$(basename "$resource")"
done
ICON_NAME="EarthProIcon-$(shasum -a 256 "$ROOT_DIR/Sources/EarthPro/Resources/EarthProIcon.icns" | cut -c1-12)"
cp "$ROOT_DIR/Sources/EarthPro/Resources/EarthProIcon.icns" "$BUNDLE/Contents/Resources/$ICON_NAME.icns"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EarthPro</string>
<key>CFBundleIdentifier</key><string>local.earthpro.app</string>
<key>CFBundleName</key><string>Earth Pro</string>
<key>CFBundleDisplayName</key><string>Earth Pro</string>
<key>CFBundleIconFile</key><string>EarthProIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>KML Places</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>CFBundleTypeExtensions</key><array><string>kml</string><string>kmz</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -replace CFBundleIconFile -string "$ICON_NAME" "$BUNDLE/Contents/Info.plist"
xattr -cr "$BUNDLE"
codesign --force --deep --sign - "$BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$BUNDLE"
mkdir -p "$ROOT_DIR/dist"
if [[ ! -L "$ROOT_DIR/dist/Earth Pro.app" ]]; then
    rm -rf "$ROOT_DIR/dist/Earth Pro.app"
    ln -s "$BUNDLE" "$ROOT_DIR/dist/Earth Pro.app"
fi
case "$MODE" in
  --build-only) echo "$BUNDLE" ;;
  --debug) exec lldb "$BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|--telemetry) open -n "$BUNDLE"; exec /usr/bin/log stream --info --predicate 'process == "EarthPro"' ;;
  --verify) open -n "$BUNDLE"; sleep 2; pgrep -x "$APP_NAME" ;;
  run) open -n "$BUNDLE" ;;
  *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
