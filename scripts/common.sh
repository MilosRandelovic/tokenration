#!/usr/bin/env bash

# Shared bundle assembly, sourced by build-app.sh and release.sh.
# SHORT_VERSION is the release version: bumping it and pushing to main publishes a release.
APP_NAME="TokenRation"
MCP_NAME="tokenration-mcp"
BUNDLE_ID="com.milosrandelovic.tokenration"
SHORT_VERSION="1.0.3"
BUILD_VERSION="1"
MIN_MACOS="14.0"
ICON_NAME="AppIcon"

# Build the release binary and lay out <APP_NAME>.app (unsigned).
# Sets $APP to the bundle path for the caller.
assemble_bundle() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$root"

  echo "==> Building release"
  # SwiftPM passes the deployment target to the linker but not the SDK version, so ld stamps
  # LC_BUILD_VERSION's sdk field with the deployment target instead of the SDK actually used.
  # AppKit reads that stamp to pick a control's appearance, so without this a local build renders
  # system controls as macOS 14 would while the released build renders them as its own SDK does.
  local sdkVersion
  sdkVersion="$(xcrun --show-sdk-version)"
  swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$sdkVersion"
  local binDir="$(swift build -c release --show-bin-path)"
  local bin="$binDir/$APP_NAME"

  APP="$root/$APP_NAME.app"
  local contents="$APP/Contents"
  echo "==> Assembling $APP_NAME.app"
  rm -rf "$APP"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  cp "$bin" "$contents/MacOS/$APP_NAME"
  # Bundled MCP server; the Homebrew cask symlinks this onto the PATH.
  cp "$binDir/$MCP_NAME" "$contents/MacOS/$MCP_NAME"
  # LSUIElement keeps it out of the Dock, but Finder, Spotlight, the About panel and every
  # notification still show the icon.
  cp "$root/Resources/$ICON_NAME.icns" "$contents/Resources/$ICON_NAME.icns"

  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>CFBundleIconFile</key><string>$ICON_NAME</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}
