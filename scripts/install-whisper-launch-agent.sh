#!/bin/bash
set -euo pipefail

LABEL='com.obsidianwhisper.local-server'
PORT='8090'
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/ggml-large-v3-turbo-q5_0.bin" >&2
  exit 2
fi
MODEL_FILE="$1"
[[ -f "$MODEL_FILE" ]] || { echo "Whisper model file not found: $MODEL_FILE" >&2; exit 1; }
command -v brew >/dev/null 2>&1 || { echo 'Install Homebrew first.' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required to generate the LaunchAgent plist.' >&2; exit 1; }

BREW_PREFIX="$(brew --prefix whisper.cpp)"
SERVER="$BREW_PREFIX/bin/whisper-server"
[[ -x "$SERVER" ]] || { echo "whisper-server not found: $SERVER" >&2; exit 1; }
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use; refusing to start a duplicate Whisper server." >&2
  exit 1
fi

UID_NUM="$(id -u)"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "LaunchAgent $LABEL is already loaded; refusing to replace it." >&2
  exit 1
fi

AGENT_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/whisper-server"
PLIST="$AGENT_DIR/$LABEL.plist"
[[ ! -e "$PLIST" ]] || { echo "Refusing to overwrite existing plist: $PLIST" >&2; exit 1; }
mkdir -p "$AGENT_DIR" "$LOG_DIR"

python3 - "$PLIST" "$SERVER" "$MODEL_FILE" "$LOG_DIR" "$LABEL" <<'PY'
import plistlib, sys
from pathlib import Path

plist_path, server, model, logs, label = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [
        server, "--model", str(Path(model).expanduser()),
        "--host", "127.0.0.1", "--port", "8090",
        "--convert", "--inference-path", "/v1/audio/transcriptions",
        "-l", "auto",
    ],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Interactive",
    "WorkingDirectory": str(Path.home()),
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    "StandardOutPath": str(Path(logs) / "out.log"),
    "StandardErrorPath": str(Path(logs) / "err.log"),
}
with open(plist_path, "wb") as f:
    plistlib.dump(payload, f, fmt=plistlib.FMT_XML, sort_keys=False)
PY
chmod 600 "$PLIST"
if ! launchctl bootstrap "gui/$UID_NUM" "$PLIST"; then
  rm -f "$PLIST"
  echo 'launchctl failed to load the server; the generated plist was removed.' >&2
  exit 1
fi
echo "Installed and loaded $LABEL. Whisper listens only on 127.0.0.1:$PORT."
echo "Logs: $LOG_DIR"
