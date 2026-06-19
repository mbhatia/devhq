#!/bin/sh
set -eu

DEVHQ_REPOSITORY_URL="${DEVHQ_REPOSITORY_URL:-https://github.com/mbhatia/devhq}"
DEVHQ_LPM_RELEASE_URL="${DEVHQ_LPM_RELEASE_URL:-https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest}"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

download() {
  url="$1"
  dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
  else
    die "missing curl or wget"
  fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
    *) die "unsupported operating system: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64' ;;
    arm64 | aarch64) printf 'aarch64' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

need_cmd uname
need_cmd chmod
need_cmd mktemp

os="$(detect_os)"
arch="$(detect_arch)"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/devhq-install.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

lpm="$tmpdir/lpm"
lpm_url="$DEVHQ_LPM_RELEASE_URL/lpm.$arch-$os"

log "Installing DevHQ for $os/$arch"
log "Downloading Lite XL Package Manager..."
download "$lpm_url" "$lpm"
chmod +x "$lpm"

log "Installing Lite XL..."
"$lpm" install lite-xl

log "Adding DevHQ package repository..."
if ! "$lpm" repo add "$DEVHQ_REPOSITORY_URL"; then
  log "DevHQ repository may already be configured; continuing."
fi

log "Installing DevHQ..."
"$lpm" install devhq

log "DevHQ installation complete."
log "Open Lite XL to start using DevHQ."
