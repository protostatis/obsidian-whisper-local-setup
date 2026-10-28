#!/bin/bash
set -euo pipefail

TARGET_SHA256='2b5316b27ba80e35b384640596f695f90973061c42e90c47c58becd1462b56d7'
BASE_SHA256='46adc9a2a201c77f2fa18ef88aed61801f099416818f229985d25c07e4cfdbbc'

[[ $# -eq 1 ]] || { echo "Usage: $0 /path/to/Obsidian-vault" >&2; exit 2; }
PLUGIN_DIR="$1/.obsidian/plugins/whisper"
MAIN_JS="$PLUGIN_DIR/main.js"
BACKUP="$PLUGIN_DIR/main.js.pre-long-audio-patch"
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }

[[ -f "$MAIN_JS" && -f "$BACKUP" ]] || { echo 'Patched bundle or rollback copy is missing.' >&2; exit 1; }
[[ "$(hash_file "$MAIN_JS")" == "$TARGET_SHA256" ]] || {
  echo 'Current main.js is not the reviewed patched bundle; refusing to replace it.' >&2
  exit 1
}
[[ "$(hash_file "$BACKUP")" == "$BASE_SHA256" ]] || {
  echo 'Rollback copy checksum does not match the pristine Whisper 1.9.1 bundle.' >&2
  exit 1
}
TMP="$PLUGIN_DIR/.main.js.$$.rollback"
cp -p "$BACKUP" "$TMP"
mv -f "$TMP" "$MAIN_JS"
echo 'Restored the pristine Whisper 1.9.1 main.js. Reload Obsidian to activate it.'
