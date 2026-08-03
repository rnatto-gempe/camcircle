#!/bin/bash
# Compila o CamCircle.app (webcam em círculo flutuante) usando só o toolchain do macOS.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/CamCircle.app"

echo "==> Limpando build anterior"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "==> Gerando Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>CamCircle</string>
    <key>CFBundleDisplayName</key>     <string>CamCircle</string>
    <key>CFBundleExecutable</key>      <string>CamCircle</string>
    <key>CFBundleIdentifier</key>      <string>com.startse.camcircle</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSCameraUsageDescription</key>
    <string>Mostrar sua webcam em um círculo flutuante para gravações de tela.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Fazer o anel reagir à sua voz (opcional, só quando você liga o efeito).</string>
</dict>
</plist>
PLIST

echo "==> Compilando (swiftc)"
swiftc -O \
    -framework AppKit -framework AVFoundation \
    "$DIR/CamCircle.swift" \
    -o "$APP/Contents/MacOS/CamCircle"

echo "==> Gerando entitlements"
# Sob hardened runtime, o acesso a câmera e microfone precisa ser declarado.
ENT="$(mktemp -t camcircle-ent).plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>     <true/>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
PLIST

# Hardened runtime (--options runtime) faz o dyld ignorar DYLD_INSERT_LIBRARIES e
# ativa library validation. Sem isso, qualquer processo rodando como o usuário
# poderia injetar código no app e herdar a permissão de câmera já concedida.
echo "==> Assinando (ad-hoc + hardened runtime)"
codesign --force --options runtime --entitlements "$ENT" \
    --sign - --identifier com.startse.camcircle "$APP"
rm -f "$ENT"

echo "==> Conferindo a assinatura"
codesign --verify --strict --verbose=1 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "flags=" | sed 's/^/    /'

echo
echo "Pronto: $APP"
echo "Rode com:  open '$APP'"
