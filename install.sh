#!/bin/sh
set -eu

DEVHQ_REPOSITORY_URL="${DEVHQ_REPOSITORY_URL:-https://github.com/mbhatia/devhq}"
DEVHQ_LPM_RELEASE_URL="${DEVHQ_LPM_RELEASE_URL:-https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest}"
LITE_XL_VERSION="${LITE_XL_VERSION:-v2.1.8}"
LITE_XL_DMG_URL="${LITE_XL_DMG_URL:-}"

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

lite_xl_macos_dmg_url() {
  case "$arch" in
    aarch64) dmg_arch="arm64" ;;
    x86_64) dmg_arch="x86_64" ;;
    *) die "unsupported macOS architecture: $arch" ;;
  esac

  if [ -n "$LITE_XL_DMG_URL" ]; then
    printf '%s\n' "$LITE_XL_DMG_URL"
  else
    printf 'https://github.com/lite-xl/lite-xl/releases/download/%s/lite-xl-%s-macos-%s.dmg\n' \
      "$LITE_XL_VERSION" "$LITE_XL_VERSION" "$dmg_arch"
  fi
}

install_lite_xl_macos() {
  need_cmd diskutil
  need_cmd ditto
  need_cmd mkdir

  dmg="$tmpdir/lite-xl.dmg"
  mount_dir="$tmpdir/lite-xl-mount"
  dmg_url="$(lite_xl_macos_dmg_url)"

  log "Downloading Lite XL DMG..."
  download "$dmg_url" "$dmg"

  log "Mounting Lite XL DMG..."
  mkdir -p "$mount_dir"
  attach_output="$(diskutil image attach --readOnly --nobrowse --mountPoint "$mount_dir" "$dmg")"
  set -- $attach_output
  [ "$#" -gt 0 ] || die "failed to attach Lite XL DMG"
  mounted_disk="$1"
  mounted_mount="$mount_dir"

  source_app=""
  for app in "$mount_dir"/*.app; do
    if [ -d "$app" ]; then
      source_app="$app"
      break
    fi
  done
  [ -n "$source_app" ] || die "no .app bundle found in Lite XL DMG"

  app_name="${source_app##*/}"
  target_app="/Applications/$app_name"
  case "$target_app" in
    /Applications/*.app) ;;
    *) die "unexpected Lite XL app path: $target_app" ;;
  esac

  log "Installing $app_name to /Applications..."
  if [ -w /Applications ]; then
    rm -rf "$target_app"
    ditto "$source_app" "$target_app"
  else
    need_cmd sudo
    sudo rm -rf "$target_app"
    sudo ditto "$source_app" "$target_app"
  fi

  detach_lite_xl_dmg
  mounted_disk=""
  mounted_mount=""
}

detach_lite_xl_dmg() {
  had_mount=0

  if [ -n "$mounted_disk" ]; then
    had_mount=1
    if diskutil eject force "$mounted_disk" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if [ -n "$mounted_mount" ]; then
    had_mount=1
    if diskutil eject force "$mounted_mount" >/dev/null 2>&1; then
      return 0
    fi
    if diskutil unmount force "$mounted_mount" >/dev/null 2>&1; then
      return 0
    fi
  fi

  [ "$had_mount" = "0" ]
}

install_lite_xl() {
  case "$os" in
    darwin) install_lite_xl_macos ;;
    *) "$lpm" install lite-xl --assume-yes ;;
  esac
}

update_devhq_repository() {
  log "Updating DevHQ package repository..."
  if ! "$lpm" repo update "$DEVHQ_REPOSITORY_URL"; then
    log "DevHQ repository update failed; updating all package repositories."
    "$lpm" repo update
  fi
}

install_devhq() {
  log "Installing or upgrading DevHQ..."
  "$lpm" install devhq --assume-yes

  log "Refreshing DevHQ installation..."
  "$lpm" reinstall devhq --assume-yes
}

need_cmd uname
need_cmd chmod
need_cmd mktemp

os="$(detect_os)"
arch="$(detect_arch)"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/devhq-install.XXXXXX")"
mounted_disk=""
mounted_mount=""

cleanup() {
  if ! detach_lite_xl_dmg; then
    log "warning: failed to detach Lite XL DMG; leaving temporary files in $tmpdir"
    return
  fi
  rm -rf "$tmpdir"
}

trap cleanup EXIT HUP INT TERM

lpm="$tmpdir/lpm"
lpm_url="$DEVHQ_LPM_RELEASE_URL/lpm.$arch-$os"

log "Installing DevHQ for $os/$arch"
log "Downloading Lite XL Package Manager..."
download "$lpm_url" "$lpm"
chmod +x "$lpm"

log "Installing Lite XL..."
install_lite_xl

log "Adding DevHQ package repository..."
if ! "$lpm" repo add "$DEVHQ_REPOSITORY_URL"; then
  log "DevHQ repository may already be configured; continuing."
fi

update_devhq_repository
install_devhq

log "DevHQ installation complete."
log "Open Lite XL to start using DevHQ."
