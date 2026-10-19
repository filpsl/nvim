#!/usr/bin/env bash
# Instala o que a integração Arduino do Neovim (lua/config/arduino.lua) precisa
# fora desta pasta: o arduino-cli e o arduino-language-server com os patches de
# arduino/patches/, compilado nesta máquina. Não instala nenhum core de placa.
#
# Uso: ~/.config/nvim/arduino/setup.sh   (pode rodar de novo para reinstalar)
#
# Deixa só dois binários em ~/.local/bin (ou $BIN_DIR). Go, módulos e cache de
# compilação ficam numa pasta temporária apagada no fim; o Go só é baixado se
# não houver um Go >= 1.22 no PATH.
set -euo pipefail

ARDUINO_CLI_VERSION=1.5.1
LS_VERSION=0.7.7
LSP_LIB=go.bug.st/lsp@v0.1.3 # biblioteca que recebe o patch de UTF-16
GO_VERSION=1.27.2

BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mxx\033[0m %s\n' "$*" >&2
  exit 1
}

for cmd in git curl tar sha256sum; do
  command -v "$cmd" >/dev/null || die "falta o comando '$cmd' (instale pelo gerenciador de pacotes)"
done

case "$(uname -m)" in
  x86_64) CLI_ARCH=64bit GO_ARCH=amd64 ;;
  i?86) CLI_ARCH=32bit GO_ARCH=386 ;;
  aarch64 | arm64) CLI_ARCH=ARM64 GO_ARCH=arm64 ;;
  armv7*) CLI_ARCH=ARMv7 GO_ARCH=armv6l ;;
  *) die "arquitetura não suportada: $(uname -m)" ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN_DIR"

# --- arduino-cli ---------------------------------------------------------------
CLI=$BIN_DIR/arduino-cli
if [[ -x $CLI ]] && "$CLI" version 2>/dev/null | grep -q "Version: $ARDUINO_CLI_VERSION "; then
  info "arduino-cli $ARDUINO_CLI_VERSION já instalado"
else
  info "Baixando arduino-cli $ARDUINO_CLI_VERSION"
  file=arduino-cli_${ARDUINO_CLI_VERSION}_Linux_${CLI_ARCH}.tar.gz
  base=https://github.com/arduino/arduino-cli/releases/download/v$ARDUINO_CLI_VERSION
  curl -fsSL -o "$WORK/$file" "$base/$file"
  curl -fsSL -o "$WORK/sums.txt" "$base/$ARDUINO_CLI_VERSION-checksums.txt"
  (cd "$WORK" && grep " $file\$" sums.txt | sha256sum -c --quiet -) || die "checksum do arduino-cli não confere"
  tar -xzf "$WORK/$file" -C "$WORK" arduino-cli
  install -m755 "$WORK/arduino-cli" "$CLI"
fi

# --- configuração do arduino-cli -------------------------------------------------
CFG=$HOME/.arduino15/arduino-cli.yaml
if [[ -e $CFG || -L $CFG ]]; then
  info "Configuração do arduino-cli já existe ($CFG)"
elif [[ -f $HOME/.arduinoIDE/arduino-cli.yaml ]]; then
  # a mesma do Arduino IDE 2: os dois compartilham cores, bibliotecas e URLs de placas
  mkdir -p "$HOME/.arduino15"
  ln -s "$HOME/.arduinoIDE/arduino-cli.yaml" "$CFG"
  info "Configuração do arduino-cli ligada à do Arduino IDE"
else
  "$CLI" config init >/dev/null
  info "Configuração do arduino-cli criada em $CFG"
fi
info "Atualizando o índice de placas"
"$CLI" core update-index >/dev/null

# --- Go (só para compilar) -------------------------------------------------------
go_ok() { # aceita Go >= 1.22 (exigido pelo go.mod do language server)
  local v major minor
  v=$("$1" env GOVERSION 2>/dev/null) || return 1
  v=${v#go}
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%[!0-9]*}
  [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
  ((major > 1 || (major == 1 && minor >= 22)))
}
if command -v go >/dev/null && go_ok go; then
  GO=$(command -v go)
else
  info "Baixando Go $GO_VERSION (temporário, só para compilar)"
  file=go$GO_VERSION.linux-$GO_ARCH.tar.gz
  curl -fsSL -o "$WORK/$file" "https://dl.google.com/go/$file"
  echo "$(curl -fsSL "https://dl.google.com/go/$file.sha256")  $WORK/$file" | sha256sum -c --quiet - ||
    die "checksum do Go não confere"
  tar -xzf "$WORK/$file" -C "$WORK"
  GO=$WORK/go/bin/go
fi
# sem baixar outro toolchain por trás, sem cgo (dispensa gcc) e com caches no $WORK
export GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-modcacherw
export GOMODCACHE=$WORK/gomod GOCACHE=$WORK/gocache GOPATH=$WORK/gopath
info "Usando $("$GO" version)"

# --- arduino-language-server com os patches --------------------------------------
info "Baixando arduino-language-server $LS_VERSION"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$LS_VERSION" \
  https://github.com/arduino/arduino-language-server.git "$WORK/als"
cd "$WORK/als"
git apply "$HERE/patches/0001-references.patch"
# o bug de UTF-16 está na biblioteca go.bug.st/lsp: compila com uma cópia corrigida
"$GO" mod download "$LSP_LIB"
mkdir -p third_party
cp -r "$GOMODCACHE/$LSP_LIB" third_party/go-lsp
chmod -R u+w third_party/go-lsp
git apply --directory=third_party/go-lsp "$HERE/patches/0002-utf16-getoffset.patch"
"$GO" mod edit -replace "${LSP_LIB%@*}=./third_party/go-lsp"
(cd third_party/go-lsp && "$GO" test ./textedits/ >/dev/null) || die "os testes do patch de UTF-16 falharam"

info "Compilando o arduino-language-server (pode levar alguns minutos)"
"$GO" build -o "$WORK/arduino-language-server" .
install -m755 "$WORK/arduino-language-server" "$BIN_DIR/arduino-language-server"
info "Instalado em $BIN_DIR: arduino-cli e arduino-language-server"

# --- conferências finais ---------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR não está no PATH: adicione ao ~/.bashrc  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
if ! id -nG | grep -qw dialout; then
  warn "Seu usuário não está no grupo dialout, necessário para o upload. Rode:"
  warn "  sudo usermod -aG dialout \$USER   (e saia/entre de novo na sessão)"
fi

cat <<EOF

Pronto. Falta só:
  1. Instalar os cores das placas que você usa (nenhum foi instalado), ex.:
       arduino-cli core install arduino:avr
     Para procurar: arduino-cli core search <nome>. Placas de terceiros precisam
     da URL do fabricante antes:  arduino-cli config add board_manager.additional_urls <url>
  2. Abrir um .ino no Neovim: o clangd vem pelo Mason (extra lang.clangd do LazyVim).
EOF
