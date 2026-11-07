#!/bin/zsh
# Compile et assemble OwnMac.app (app de barre de menus, sans icône Dock)
# ./build.sh            installe dans ~/Applications et crée le zip
# ./build.sh --release  crée seulement le zip, sans toucher à l'app installée
set -e
trap 'echo "ECHEC build.sh ligne $LINENO (app non installée)" >&2' ERR
cd "$(dirname "$0")"
# Hors du projet : Documents est synchronisé par iCloud, qui entre en conflit avec les bundles recréés à chaque build
OUT=~/Library/Caches/OwnMac-build
mkdir -p "$OUT"
swift build -c release --scratch-path "$OUT/swift"
APP="$OUT/OwnMac.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$OUT/swift/release/OwnMac" "$APP/Contents/MacOS/OwnMac"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>OwnMac</string>
<key>CFBundleIdentifier</key><string>local.ownmac</string>
<key>CFBundleExecutable</key><string>OwnMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>OwnMac pilote Musique et Spotify depuis la Dynamic Island.</string>
<key>NSCameraUsageDescription</key><string>OwnMac détecte ta présence pour verrouiller l'écran quand tu t'éloignes. Rien n'est enregistré.</string>
</dict></plist>
PL
codesign --force --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/OwnMac.zip"   # archive à publier dans les Releases
if [[ "$1" == "--release" ]]; then
  rm -rf "$APP"      # évite que macOS repère une seconde copie de l'app
  echo "OK -> $OUT/OwnMac.zip (rien d'installé)"
  exit 0
fi
# Installe dans ~/Applications (emplacement stable pour le lancement au démarrage)
mkdir -p ~/Applications && rm -rf ~/Applications/OwnMac.app && cp -R "$APP" ~/Applications/
cmp -s "$APP/Contents/MacOS/OwnMac" ~/Applications/OwnMac.app/Contents/MacOS/OwnMac   # vérifie l'installation
echo "OK -> ~/Applications/OwnMac.app et $OUT/OwnMac.zip"
