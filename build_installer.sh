#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$DIST_DIR/build-installer}"
OUTPUT_DMG="${OUTPUT_DMG:-$DIST_DIR/DevHQ-macos-arm64.dmg}"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-DevHQ}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.github.mbhatia.devhq}"
VOLUME_NAME="${VOLUME_NAME:-DevHQ}"
APP_ICON_PATH="${APP_ICON_PATH:-$SCRIPT_DIR/assets/DevHQ.icns}"
LITE_XL_VERSION="${LITE_XL_VERSION:-v2.1.8}"
LITE_XL_DMG_URL="${LITE_XL_DMG_URL:-}"
LITE_XL_DMG_PATH="${LITE_XL_DMG_PATH:-}"
LPM_PATH="${LPM_PATH:-}"
SHPOOL_PATH="${SHPOOL_PATH:-}"
LUA_BIN_PATH="${LUA_BIN_PATH:-}"
CODESIGN="${CODESIGN:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CODESIGN_OPTIONS="${CODESIGN_OPTIONS:-}"

STAGE_DIR="$WORK_DIR/stage"
STAGED_APP="$STAGE_DIR/$APP_BUNDLE_NAME.app"
DMG_ROOT="$WORK_DIR/dmg-root"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

usage() {
  cat <<USAGE
Usage: ./build_installer.sh [--dry-run] [--stage-only]

Repackages the official Lite XL macOS arm64 app as DevHQ.

Environment overrides:
  LITE_XL_DMG_PATH  Existing Lite XL DMG; otherwise it is downloaded
  LITE_XL_DMG_URL   Alternate Lite XL DMG URL
  LPM_PATH           Existing lpm binary; otherwise it is downloaded
  SHPOOL_PATH        Existing arm64 shpool binary; otherwise it is built
  LUA_BIN_PATH        Existing standalone arm64 Lua; otherwise it is built
  DIST_DIR           Output directory; default: $DIST_DIR
  WORK_DIR           Staging directory; default: $WORK_DIR
  OUTPUT_DMG         Output path; default: $OUTPUT_DMG
  CODESIGN           Sign the app: 1 or 0; default: $CODESIGN
  SIGN_IDENTITY      codesign identity; default: - (ad-hoc)
  CODESIGN_OPTIONS   Extra codesign arguments
USAGE
}

DRY_RUN=0
STAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --stage-only) STAGE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

case "$CODESIGN" in
  0|1) ;;
  *) die "CODESIGN must be 0 or 1" ;;
esac
[ -x "$SCRIPT_DIR/install.sh" ] || die "missing installer: $SCRIPT_DIR/install.sh"
[ -f "$APP_ICON_PATH" ] || die "missing app icon: $APP_ICON_PATH"
[ -z "$LITE_XL_DMG_PATH" ] || [ -f "$LITE_XL_DMG_PATH" ] || die "missing Lite XL DMG: $LITE_XL_DMG_PATH"
[ -z "$LPM_PATH" ] || [ -f "$LPM_PATH" ] || die "missing lpm binary: $LPM_PATH"
[ -z "$SHPOOL_PATH" ] || [ -f "$SHPOOL_PATH" ] || die "missing shpool binary: $SHPOOL_PATH"
[ -z "$LUA_BIN_PATH" ] || [ -f "$LUA_BIN_PATH" ] || die "missing Lua binary: $LUA_BIN_PATH"

log "DevHQ macOS package plan:"
log "  App:       $STAGED_APP"
log "  Lite XL:   ${LITE_XL_DMG_PATH:-${LITE_XL_DMG_URL:-official $LITE_XL_VERSION arm64 DMG}}"
log "  Output:    $OUTPUT_DMG"
log "  Signing:   CODESIGN=$CODESIGN, SIGN_IDENTITY=$SIGN_IDENTITY"
[ "$DRY_RUN" = "0" ] || exit 0

[ "$(uname -s)" = "Darwin" ] || die "macOS is required to build a DMG"
case "$(uname -m)" in
  arm64|aarch64) ;;
  *) die "macOS arm64 is required to build this DMG" ;;
esac

need_cmd ditto
need_cmd hdiutil
need_cmd plutil
need_cmd find
need_cmd file
[ "$CODESIGN" = "0" ] || need_cmd codesign

rm -rf "$STAGE_DIR" "$DMG_ROOT"
mkdir -p "$STAGE_DIR" "$DIST_DIR"

log "Installing DevHQ into the staged app..."
DEVHQ_REPOSITORY_URL="$SCRIPT_DIR" \
DEVHQ_APP_PATH="$STAGED_APP" \
DEVHQ_LPM_PATH="$LPM_PATH" \
DEVHQ_SHPOOL_PATH="$SHPOOL_PATH" \
DEVHQ_LUA_PATH="$LUA_BIN_PATH" \
LITE_XL_VERSION="$LITE_XL_VERSION" \
LITE_XL_DMG_URL="$LITE_XL_DMG_URL" \
LITE_XL_DMG_PATH="$LITE_XL_DMG_PATH" \
  "$SCRIPT_DIR/install.sh"

resources_dir="$STAGED_APP/Contents/Resources"
plist="$STAGED_APP/Contents/Info.plist"
[ -f "$resources_dir/core/start.lua" ] || die "staged app is missing Lite XL"
[ -d "$resources_dir/plugins/devhq" ] || die "staged app is missing DevHQ"
[ -d "$resources_dir/plugins/web" ] || die "staged app is missing web"
[ -d "$resources_dir/plugins/ghostty" ] || die "staged app is missing ghostty"
[ -f "$resources_dir/libraries/web_lxl/init.lib" ] || die "staged app is missing web_lxl"
[ -f "$resources_dir/libraries/ghostty_lxl/init.lib" ] || die "staged app is missing ghostty_lxl"
[ -x "$resources_dir/bin/devhq" ] || die "staged app is missing the devhq CLI"
[ -x "$resources_dir/bin/lpm" ] || die "staged app is missing the lpm CLI"
[ -x "$resources_dir/bin/shpool" ] || die "staged app is missing the shpool CLI"
[ -x "$resources_dir/bin/lua" ] || die "staged app is missing the Lua interpreter"
[ -f "$resources_dir/licenses.md" ] || die "staged app is missing Lite XL licenses"
[ -f "$resources_dir/legal/DevHQ-LICENSE" ] || die "staged app is missing the DevHQ license"
[ -f "$resources_dir/legal/lpm-LICENSE" ] || die "staged app is missing the lpm license"
[ -f "$resources_dir/legal/shpool-LICENSE" ] || die "staged app is missing the shpool license"
[ -f "$resources_dir/legal/lua-LICENSE.html" ] || die "staged app is missing the Lua license"
[ -f "$resources_dir/legal/THIRD-PARTY-NOTICES.md" ] || die "staged app is missing third-party notices"
[ -f "$plist" ] || die "staged app is missing Info.plist"

log "Branding the staged app..."
plutil -replace CFBundleName -string "$APP_BUNDLE_NAME" "$plist"
plutil -replace CFBundleDisplayName -string "$APP_BUNDLE_NAME" "$plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$plist"
plutil -replace CFBundleIconFile -string icon.icns "$plist"
ditto "$APP_ICON_PATH" "$resources_dir/icon.icns"

codesign_path() {
  local path="$1"
  local args=(--force)
  if [ -n "$CODESIGN_OPTIONS" ]; then
    read -r -a extra_args <<< "$CODESIGN_OPTIONS"
    args+=("${extra_args[@]}")
  fi
  codesign "${args[@]}" --sign "$SIGN_IDENTITY" "$path" >/dev/null
}

if [ "$CODESIGN" = "1" ]; then
  log "Signing nested native code..."
  while IFS= read -r native_path; do
    codesign_path "$native_path"
  done < <(find "$STAGED_APP/Contents" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ { print $1 }')

  log "Signing the app..."
  codesign_path "$STAGED_APP"
  codesign --verify --deep --strict --verbose=2 "$STAGED_APP" >/dev/null
fi

if [ "$STAGE_ONLY" = "1" ]; then
  log "Created staged app: $STAGED_APP"
  exit 0
fi

mkdir -p "$DMG_ROOT"
ditto "$STAGED_APP" "$DMG_ROOT/$APP_BUNDLE_NAME.app"
cp "$resources_dir/licenses.md" "$DMG_ROOT/Lite XL Licenses.md"
cp "$resources_dir/legal/DevHQ-LICENSE" "$DMG_ROOT/DevHQ License.txt"
cp "$resources_dir/legal/THIRD-PARTY-NOTICES.md" "$DMG_ROOT/THIRD-PARTY-NOTICES.md"
ln -s /Applications "$DMG_ROOT/Applications"

log "Creating $OUTPUT_DMG..."
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$OUTPUT_DMG" >/dev/null
hdiutil verify "$OUTPUT_DMG" >/dev/null
log "Created $OUTPUT_DMG"
