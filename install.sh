#!/bin/bash
# Compila, instala em ~/Applications, cria o comando `cam` e liga todos os efeitos.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
APP="$HOME/Applications/CamCircle.app"

"$DIR/build.sh"

echo "==> Instalando em ~/Applications"
mkdir -p "$HOME/Applications"
pkill -x CamCircle 2>/dev/null || true
rm -rf "$APP"
cp -R "$DIR/CamCircle.app" "$APP"

echo "==> Instalando o comando 'cam' em $BIN"
mkdir -p "$BIN"
install -m 755 "$DIR/cam" "$BIN/cam"

if ! echo ":$PATH:" | grep -q ":$BIN:"; then
    echo "   Aviso: $BIN não está no PATH. Adicione ao ~/.zshrc:"
    echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo "==> Ligando todos os efeitos"
"$BIN/cam" all >/dev/null

cat <<TXT

Pronto.

  cam          abre o círculo
  cam all      abre com todos os efeitos
  cam stop     fecha
  cam --help   todas as opções

TXT
