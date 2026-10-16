#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP_PATH="$PWD/build/ModelDock.app"
MM_TARGET="arm64-apple-macosx14.0"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$PWD/build/ModuleCache"
cp "$PWD/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$PWD/Resources/gateway.py" "$APP_PATH/Contents/Resources/gateway.py"
cp "$PWD/Resources/strata.py" "$APP_PATH/Contents/Resources/strata.py"
cp "$PWD/Resources/app_update.py" "$APP_PATH/Contents/Resources/app_update.py"
cp "$PWD/LICENSE" "$PWD/LICENSE-NOTICE.txt" "$APP_PATH/Contents/Resources/"
/usr/bin/ditto "$PWD/Resources/Localization" "$APP_PATH/Contents/Resources/Localization"
if [ -d "$PWD/Resources/ThirdPartyNotices" ]; then
  /usr/bin/ditto "$PWD/Resources/ThirdPartyNotices" "$APP_PATH/Contents/Resources/ThirdPartyNotices"
fi
/usr/bin/clang -target "$MM_TARGET" -dynamiclib Sources/ProcessIdentity.c -lproc -Wl,-install_name,@loader_path/ProcessIdentity.dylib -o "$APP_PATH/Contents/Resources/ProcessIdentity.dylib"
/usr/bin/codesign --force --sign - "$APP_PATH/Contents/Resources/ProcessIdentity.dylib"
/usr/bin/clang -target "$MM_TARGET" -c Sources/ProcessIdentity.c -o "$PWD/build/ProcessIdentity.o"
/usr/bin/swiftc -target "$MM_TARGET" -file-prefix-map "$PWD=/ModelManager" -swift-version 5 -O -parse-as-library -import-objc-header Sources/ProcessIdentity.h -module-cache-path "$PWD/build/ModuleCache" Sources/*.swift "$PWD/build/ProcessIdentity.o" -lproc -framework AppKit -framework SwiftUI -o "$APP_PATH/Contents/MacOS/ModelManager"
if [ -n "${MM_PYTHON_RUNTIME_DIR:-}" ]; then
  test -x "$MM_PYTHON_RUNTIME_DIR/bin/python3"
  /usr/bin/ditto "$MM_PYTHON_RUNTIME_DIR" "$APP_PATH/Contents/Resources/PythonRuntime"
  cp Resources/python-runtime.json "$APP_PATH/Contents/Resources/python-runtime.json"
  /usr/bin/codesign --force --deep --sign - "$APP_PATH/Contents/Resources/PythonRuntime/bin/python3.13"
fi
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.null.ModelManager</string>
<key>CFBundleName</key><string>ModelDock</string>
<key>CFBundleDisplayName</key><string>ModelDock</string>
<key>CFBundleExecutable</key><string>ModelManager</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.3</string>
<key>CFBundleVersion</key><string>33</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>fr</string><string>pt</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_PATH"
printf '%s\n' "$APP_PATH"
