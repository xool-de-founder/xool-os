#!/bin/bash
# Builds "Xool OS.app": SwiftPM builds the executable, and a macOS app bundle
# is just a folder with a plist and the binary in the right place.
#
#   ./build.sh            release build, ad-hoc signed: runs on this Mac
#   ./build.sh debug      the same from a debug build (faster to make)
#
# Output: build/Xool OS.app. Based on Search's build script (MIT).
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
ARCH="${XOOL_ARCH:-$(uname -m)}"
OUT="build"
NAME="Xool OS"
EXECUTABLE="XoolOS"
APP="$OUT/$NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
MINIMUM="14.0"

SWIFTFLAGS=(-c "$CONFIG" --arch "$ARCH")
[ "$CONFIG" = "release" ] && SWIFTFLAGS+=(-Xswiftc -Osize)

# App Intents (Sources/XoolOS/Xool/JarvisIntent.swift): the build writes out
# the constant values of everything that conforms to AppIntent & co.
# (*.swiftconstvalues), and appintentsmetadataprocessor (below) turns them into
# Metadata.appintents, which is what makes Shortcuts and Spotlight find
# "Talk to Jarvis".
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"

swift build "${SWIFTFLAGS[@]}" --product "$EXECUTABLE"
BIN_PATH="$(swift build "${SWIFTFLAGS[@]}" --show-bin-path)"
BINARY="$BIN_PATH/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"

# The binary says which SDK it was built with, and AppKit draws the app the
# way that SDK's macOS drew it: put the real SDK back (SwiftPM writes the
# oldest macOS the app runs on into both fields).
SDK="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos "$MINIMUM" "$SDK" -replace \
  -output "$APP/Contents/MacOS/$EXECUTABLE.sdk" "$APP/Contents/MacOS/$EXECUTABLE"
mv "$APP/Contents/MacOS/$EXECUTABLE.sdk" "$APP/Contents/MacOS/$EXECUTABLE"

# The AppleScript dictionary (Scripting.swift): read-only, tabs' addresses
# and titles.
cp Xool.sdef "$APP/Contents/Resources/"
# The one-command setup (Settings > Models > Set up local AI runs it).
cp scripts/xool-setup.sh "$APP/Contents/Resources/"
# Resources/canvas is the built Canvas (TipTap block editor + surface engine),
# checked in; rebuild it from web/canvas with web/canvas/build.sh (needs Node,
# only for that: this script needs none).
[ -f Resources/canvas/index.html ] || { echo "Resources/canvas is missing: run web/canvas/build.sh"; exit 1; }
[ -d Resources ] && cp -R Resources/. "$APP/Contents/Resources/" || true
find "$APP/Contents/Resources" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

if [ "$CONFIG" = "release" ]; then
  strip -x "$APP/Contents/MacOS/$EXECUTABLE"
fi

# The icon, drawn fresh each time (Icon/icon.swift).
ICONSET="$OUT/AppIcon.iconset"
ICONDOC="$OUT/AppIcon.icon"
rm -rf "$ICONSET" "$ICONDOC"
swift Icon/icon.swift "$ICONSET" "$ICONDOC" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$ICONDOC"

# Metadata.appintents, from what the compiler wrote out above. Without it the
# app still runs; Shortcuts just doesn't list its intent.
CONSTS="$OUT/appintents-constvalues.txt"
SOURCES="$OUT/appintents-sources.txt"
CAP="$(echo "$CONFIG" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
find ".build/out/Intermediates.noindex/$EXECUTABLE.build/$CAP" -path "*/$ARCH/*" -name '*.swiftconstvalues' -size +2c > "$CONSTS" 2>/dev/null || true
find Sources/XoolOS -name '*.swift' > "$SOURCES"
if [ -s "$CONSTS" ]; then
  xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name "$EXECUTABLE" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS \
    --deployment-target "$MINIMUM" \
    --target-triple "$ARCH-apple-macosx$MINIMUM" \
    --source-file-list "$SOURCES" \
    --swift-const-vals-list "$CONSTS" \
    --quiet-warnings || echo "note: App Intents metadata was not written (Shortcuts won't list the intent)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>com.xool.os</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Xool OS · based on Search (MIT)</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>Xool.sdef</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>Email address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>mailto</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including localhost, and a
       local model (Ollama, LM Studio) answers over plain http there. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Xool OS uses the local network to open pages on devices in your home or office, and to reach a model running on this Mac.</string>
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Xool OS asks you the first time each site does.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Xool OS listens while you hold the talk key or press the mic button, to hear what you ask an agent. Websites you visit can also ask to use your microphone; Xool OS asks you the first time each site does.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>When the Whisper voice is not set up, Xool OS uses the Mac's speech recognition to turn what you say to an agent into text.</string>
  <key>NSLocationUsageDescription</key>
  <string>Websites you visit can ask for your location. Xool OS asks you each time a site does.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Websites you visit can ask for your location. Xool OS asks you each time a site does.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
  <key>NSContactsUsageDescription</key>
  <string>Xool OS fills in forms with the details on your own card in Contacts, once you turn that on.</string>
</dict>
</plist>
PLIST

# Ad-hoc signed: enough to run on the machine that built it. With a certificate of your own in the keychain
# (XOOL_SIGN_ID="Name of the certificate") the signature stays the same from build to build, and macOS keeps
# the microphone approval.
SIGN_ID="${XOOL_SIGN_ID:--}"
codesign --force --deep --sign "$SIGN_ID" --entitlements Xool.entitlements "$APP"
echo "built: $APP ($VERSION, $ARCH, build $BUILD, signed: $([ "$SIGN_ID" = "-" ] && echo "ad hoc" || echo "$SIGN_ID"))"
if [ "$SIGN_ID" = "-" ]; then
  echo "note: an ad-hoc signature is new with every build, so macOS forgets the microphone approval."
  echo "      After copying the app to /Applications run:  tccutil reset Microphone com.xool.os"
  echo "      then start it and allow the microphone once (or set XOOL_SIGN_ID to a local certificate)."
fi
