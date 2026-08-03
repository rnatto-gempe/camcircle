#!/bin/bash
# Compila CamCircle.app (webcam em círculo) e Teleprompter.app (invisível na captura)
# usando só o toolchain do macOS.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Entitlements do CamCircle: sob hardened runtime, câmera e microfone precisam
# ser declarados explicitamente.
CAM_ENT="$(mktemp -t camcircle-ent).plist"
cat > "$CAM_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>     <true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.microphone</key><true/>
</dict>
</plist>
PLIST
CC_ENT="$(mktemp -t captions-ent).plist"
cat > "$CC_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.microphone</key><true/>
</dict>
</plist>
PLIST
trap 'rm -f "$CAM_ENT" "$CC_ENT"' EXIT

# build_app <nome> <fonte.swift> <bundle-id> <frameworks> [entitlements] [chaves-extra-do-plist]
build_app() {
    local name="$1" source="$2" bundle_id="$3" frameworks="$4" ent="${5:-}" extra="${6:-}"
    local app="$DIR/$name.app"

    echo "==> $name: montando o bundle"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    # Ícone: a App Store rejeita antes de qualquer outra análise se faltar.
    if [ -f "$DIR/icons/$name.icns" ]; then
        cp "$DIR/icons/$name.icns" "$app/Contents/Resources/$name.icns"
    fi

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$name</string>
    <key>CFBundleDisplayName</key>       <string>$name</string>
    <key>CFBundleExecutable</key>        <string>$name</string>
    <key>CFBundleIdentifier</key>        <string>$bundle_id</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>$name</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.video</string>
    <key>NSHumanReadableCopyright</key>  <string>MIT License</string>
    <!-- Exigido pelo App Store Connect: nenhum dos apps usa criptografia. -->
    <key>ITSAppUsesNonExemptEncryption</key> <false/>
$extra
</dict>
</plist>
PLIST

    echo "==> $name: compilando"
    # Companion.swift é a ponte entre os dois apps e vai nos dois binários.
    # shellcheck disable=SC2086
    extra_sources=""
    [ "$name" = "Captions" ] && extra_sources="$DIR/AudioSources.swift"
    # shellcheck disable=SC2086
    swiftc -O $frameworks "$DIR/$source" "$DIR/Companion.swift" $extra_sources \
        -o "$app/Contents/MacOS/$name"

    # Hardened runtime (--options runtime) faz o dyld ignorar DYLD_INSERT_LIBRARIES
    # e ativa library validation. Sem isso, qualquer processo do usuário poderia
    # injetar código e herdar as permissões já concedidas ao app.
    echo "==> $name: assinando (ad-hoc + hardened runtime)"
    if [ -n "$ent" ]; then
        codesign --force --options runtime --entitlements "$ent" \
            --sign - --identifier "$bundle_id" "$app"
    else
        codesign --force --options runtime --sign - --identifier "$bundle_id" "$app"
    fi
    codesign --verify --strict "$app"
    codesign -dv "$app" 2>&1 | grep -E "flags=" | sed 's/^/    /'
}

build_app CamCircle CamCircle.swift com.startse.camcircle \
    "-framework AppKit -framework AVFoundation -framework Carbon" \
    "$CAM_ENT" \
    '    <key>NSCameraUsageDescription</key>
    <string>Mostrar sua webcam em um círculo flutuante para gravações de tela.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Fazer o anel reagir à sua voz (opcional, só quando você liga o efeito).</string>'

# O teleprompter não acessa câmera, microfone, disco protegido nem rede,
# então não precisa de nenhuma entitlement.
build_app Teleprompter Teleprompter.swift com.startse.teleprompter \
    "-framework AppKit -framework Carbon"

build_app Captions Captions.swift com.startse.captions \
    "-framework AppKit -framework AVFoundation -framework Carbon -framework Speech -framework CoreAudio" \
    "$CC_ENT" \
    '    <key>NSMicrophoneUsageDescription</key>
    <string>Transcrever sua fala em legendas na tela.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Gerar as legendas localmente, sem enviar audio para servidores.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Transcrever o audio que sai do sistema, para legendar reunioes e videos.</string>'

echo
echo "Pronto:"
echo "  $DIR/CamCircle.app"
echo "  $DIR/Teleprompter.app"
echo "  $DIR/Captions.app"
