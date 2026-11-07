#!/bin/zsh
# Compile et assemble OwnMac.app (app de barre de menus, sans icône Dock)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/OwnMac.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/OwnMac "$APP/Contents/MacOS/OwnMac"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>OwnMac</string>
<key>CFBundleIdentifier</key><string>local.ownmac</string>
<key>CFBundleExecutable</key><string>OwnMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP"
# Installe dans ~/Applications (emplacement stable pour le lancement au démarrage)
mkdir -p ~/Applications && rm -rf ~/Applications/OwnMac.app && cp -R "$APP" ~/Applications/
echo "OK -> $APP   (lance avec: open ~/Applications/OwnMac.app)"
