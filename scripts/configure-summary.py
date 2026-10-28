#!/usr/bin/env python3
"""Safely enable Whisper post-processing with a loopback Ollama endpoint."""
import argparse
import json
import os
import stat
import tempfile
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import urlopen


def loopback_base_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "http" or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("Ollama URL must be HTTP on loopback (localhost, 127.0.0.1, or ::1).")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Do not put credentials, query strings, or fragments in the Ollama URL.")
    path = parsed.path.rstrip("/")
    if path not in {"", "/v1"}:
        raise ValueError("Use the Ollama base URL, e.g. http://127.0.0.1:11435, not a chat-completions path.")
    return f"{parsed.scheme}://{parsed.netloc}"


def fetch_models(base_url: str) -> set[str]:
    with urlopen(f"{base_url}/v1/models", timeout=5) as response:
        payload = json.load(response)
    return {
        item["id"] for item in payload.get("data", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", required=True, type=Path, help="Path to the Obsidian vault")
    parser.add_argument("--ollama-base-url", default="http://127.0.0.1:11435")
    parser.add_argument("--model", default="qwen3.5:9b")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        base_url = loopback_base_url(args.ollama_base_url)
        models = fetch_models(base_url)
    except (ValueError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        parser.error(f"Cannot verify the local Ollama endpoint: {exc}")
    if args.model not in models:
        parser.error(f"Model {args.model!r} is not advertised by {base_url}; available: {', '.join(sorted(models)) or '(none)'}")

    plugin_dir = args.vault.expanduser() / ".obsidian" / "plugins" / "whisper"
    manifest_path = plugin_dir / "manifest.json"
    settings_path = plugin_dir / "data.json"
    prompt_path = Path(__file__).resolve().parents[1] / "config" / "summary-prompt.txt"
    if not manifest_path.is_file() or not settings_path.is_file():
        parser.error(f"Whisper plugin settings not found in {plugin_dir}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        parser.error(f"Could not read the Whisper plugin files: {exc}")
    if manifest.get("id") != "whisper":
        parser.error(f"Unexpected plugin ID: {manifest.get('id')!r}")
    prompt = prompt_path.read_text(encoding="utf-8").strip()
    updates = {
        "apiUrl": "http://127.0.0.1:8090/v1/audio/transcriptions",
        "model": "whisper-1",
        "saveAudioFile": True,
        "audioSavePath": "Inbox/Transcripts/audio",
        "createNoteFile": True,
        "noteSavePath": "Inbox/Transcripts",
        "noteFilenameTemplate": "{{title}}",
        "noteTemplate": "---\ncreated: {{datetime}}\nsource: whisper\n---\n\n![[{{audioFile}}]]\n\n{{transcription}}",
        "debugMode": True,
        "postProcessing": True,
        "postProcessingProvider": "custom",
        "postProcessingUrl": f"{base_url}/v1/chat/completions",
        "postProcessingModel": args.model,
        # Ollama ignores this placeholder; the plugin requires a non-empty bearer value.
        "postProcessingApiKey": "ollama",
        "postProcessingPrompt": prompt,
        "keepOriginalTranscription": True,
    }
    if all(settings.get(key) == value for key, value in updates.items()):
        print(f"Already configured for {args.model} at {base_url}; no changes made.")
        return 0
    print(f"Verified {args.model} at {base_url}.")
    if args.dry_run:
        print("Dry run: would enable summaries and retain the raw transcript; no files changed.")
        return 0

    original = settings_path.read_bytes()
    mode = stat.S_IMODE(settings_path.stat().st_mode)
    settings.update(updates)
    output = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup_path = plugin_dir / f"data.json.pre-local-whisper-setup-{stamp}"
    backup_path.write_bytes(original)
    backup_path.chmod(0o600)
    fd, temp_name = tempfile.mkstemp(prefix=".data.json.", dir=plugin_dir)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(output)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, settings_path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    print(f"Enabled automatic summaries with {args.model}; raw transcript retention is on.")
    print(f"Rollback settings copy: {backup_path}")
    print("Save open notes and reload Obsidian before recording.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
