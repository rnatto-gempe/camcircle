#!/bin/bash
# Compila os três apps, instala em ~/Applications e cria o comando `cam`.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
APPS=(CamCircle Teleprompter Captions)

"$DIR/build.sh"

echo "==> Instalando em ~/Applications"
mkdir -p "$HOME/Applications"
for name in "${APPS[@]}"; do
    target="$HOME/Applications/$name.app"
    pkill -x "$name" 2>/dev/null || true
    rm -rf "$target"
    cp -R "$DIR/$name.app" "$target"
    echo "    $name.app"
done

echo "==> Instalando o comando 'cam' em $BIN"
mkdir -p "$BIN"
install -m 755 "$DIR/cam" "$BIN/cam"

if ! echo ":$PATH:" | grep -q ":$BIN:"; then
    echo "   Aviso: $BIN não está no PATH. Adicione ao ~/.zshrc:"
    echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo "==> Ligando os efeitos visuais do círculo"
"$BIN/cam" all >/dev/null

cat <<'TXT'

Pronto. Os três apps estão em ~/Applications.

  cam                círculo da câmera
  cam tp             teleprompter (invisível na gravação)
  cam cc             legendas ao vivo do microfone
  cam cc system on   legendas também do áudio do sistema
  cam h              ajuda completa

As legendas exigem o Ditado ativo em
Ajustes do Sistema > Teclado > Ditado, no idioma que você usar.

TXT
