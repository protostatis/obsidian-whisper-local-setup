#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/whisper-1.9.1-loopback-chunking.patch"
EXPECTED_VERSION='1.9.1'
BASE_SHA256='46adc9a2a201c77f2fa18ef88aed61801f099416818f229985d25c07e4cfdbbc'
PATCH_SHA256='179432c1815546cf640e947f2b23e359b6470b4ba113c919a1630e275d7c4863'
TARGET_SHA256='2b5316b27ba80e35b384640596f695f90973061c42e90c47c58becd1462b56d7'

usage() {
  echo "Usage: $0 [--dry-run] /path/to/Obsidian-vault" >&2
  exit 2
}

DRY_RUN=0
if [[ "${1:-}" == '--dry-run' ]]; then
  DRY_RUN=1
  shift
fi
[[ $# -eq 1 ]] || usage
VAULT="$1"
PLUGIN_DIR="$VAULT/.obsidian/plugins/whisper"
MAIN_JS="$PLUGIN_DIR/main.js"
MANIFEST="$PLUGIN_DIR/manifest.json"
BACKUP="$PLUGIN_DIR/main.js.pre-long-audio-patch"

for tool in python3 patch shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required command not found: $tool" >&2; exit 1; }
done
[[ -f "$MAIN_JS" && -f "$MANIFEST" ]] || {
  echo "Whisper plugin not found at: $PLUGIN_DIR" >&2
  exit 1
}
[[ -f "$PATCH_FILE" ]] || { echo "Patch missing: $PATCH_FILE" >&2; exit 1; }

PLUGIN_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$MANIFEST")"
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", ""))' "$MANIFEST")"
[[ "$PLUGIN_ID" == 'whisper' ]] || { echo "Unexpected plugin ID: $PLUGIN_ID" >&2; exit 1; }
[[ "$PLUGIN_VERSION" == "$EXPECTED_VERSION" ]] || {
  echo "Unsupported Whisper version $PLUGIN_VERSION (expected $EXPECTED_VERSION); refusing to patch." >&2
  exit 1
}

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
[[ "$(hash_file "$PATCH_FILE")" == "$PATCH_SHA256" ]] || {
  echo 'Patch checksum mismatch; refusing to apply.' >&2
  exit 1
}
CURRENT_SHA256="$(hash_file "$MAIN_JS")"
if [[ "$CURRENT_SHA256" == "$TARGET_SHA256" ]]; then
  echo 'Long-audio patch is already installed; no changes made.'
  exit 0
fi
[[ "$CURRENT_SHA256" == "$BASE_SHA256" ]] || {
  echo "Unexpected main.js checksum $CURRENT_SHA256; refusing to modify this plugin bundle." >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whisper-patch.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
cp -p "$MAIN_JS" "$TMP_DIR/main.js"
(cd "$TMP_DIR" && patch -f -F 0 -p1 < "$PATCH_FILE")
[[ "$(hash_file "$TMP_DIR/main.js")" == "$TARGET_SHA256" ]] || {
  echo 'Patched output checksum did not match the reviewed target; refusing to install.' >&2
  exit 1
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo 'Dry run passed: the reviewed patch applies cleanly to this Whisper bundle.'
  exit 0
fi

if [[ -e "$BACKUP" ]]; then
  [[ "$(hash_file "$BACKUP")" == "$BASE_SHA256" ]] || {
    echo "Existing rollback file differs from the expected clean bundle: $BACKUP" >&2
    exit 1
  }
else
  cp -p "$MAIN_JS" "$BACKUP"
fi

INSTALL_TMP="$PLUGIN_DIR/.main.js.$$.tmp"
cp -p "$TMP_DIR/main.js" "$INSTALL_TMP"
mv -f "$INSTALL_TMP" "$MAIN_JS"
[[ "$(hash_file "$MAIN_JS")" == "$TARGET_SHA256" ]] || {
  echo 'Installed file checksum verification failed; restore the saved backup.' >&2
  exit 1
}
echo "Patched Whisper $PLUGIN_VERSION safely. Rollback copy: $BACKUP"
echo 'Reload Obsidian after saving open notes to load the updated plugin.'
