# Obsidian Whisper: local setup

Small, fail-closed helpers for reproducing this setup on another Mac. The repository contains a narrow patch and setup tooling—not the Whisper plugin bundle, audio models, vault content, credentials, or machine-specific SSH/LaunchAgent files.

## Data flow

1. Obsidian Whisper records and saves the audio under `Inbox/Transcripts/audio` in the vault.
2. `whisper.cpp` on the Mac transcribes it through `http://127.0.0.1:8090/v1/audio/transcriptions`.
3. The patch sends recordings longer than five minutes to that **loopback** endpoint in sequential five-minute windows and combines the text. Other endpoints are left unchanged. If a window fails, the plugin reports which part failed; the saved audio remains available for a retry.
4. The transcript text (not the audio) goes over an SSH tunnel to the user's Ollama server. The configured model is `qwen3.5:9b`.
5. The note contains the summary first and the raw transcript below it. If summary generation fails, Whisper falls back to the unmodified transcript.

No cloud transcription or summarization endpoint is used by these defaults. Keep Ollama bound to loopback on the Ubuntu host; expose it to the Mac only through SSH forwarding.

## Requirements

- macOS, Obsidian, and the community Whisper plugin (`id: whisper`, **version 1.9.1** for the included patch).
- The current bundle was exercised with Obsidian 1.14.5; Whisper's manifest declares Obsidian 1.12.7 as its minimum.
- Python 3, `patch`, and `shasum` (the latter two are included with macOS developer tools).
- Homebrew `whisper.cpp` and a compatible Whisper model. The current setup uses `ggml-large-v3-turbo-q5_0.bin`; obtain it from the [official whisper.cpp model collection](https://huggingface.co/ggerganov/whisper.cpp), not from this repo.
- A running Ollama server reachable over SSH. Defaults expect the official [`qwen3.5:9b` Ollama tag](https://ollama.com/library/qwen3.5:9b) and a local SSH forward on port 11435.

## 1. Start the local Whisper server at login

Install the server and download a model separately:

```sh
brew install whisper.cpp
MODEL_DIR="$HOME/Library/Application Support/whisper-cpp/models"
mkdir -p "$MODEL_DIR"
curl -fL \
  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin' \
  -o "$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
```

Install the user LaunchAgent (it refuses to overwrite an existing one or start if port 8090 is already occupied):

```sh
./scripts/install-whisper-launch-agent.sh \
  "$HOME/Library/Application Support/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin"
```

It binds only to `127.0.0.1:8090`. Logs go to `~/Library/Logs/whisper-server/`.

## 2. Forward the private Ollama server

On each Mac, create a personal SSH host alias in `~/.ssh/config` (do not put hostnames, usernames, or keys in this repo):

```sshconfig
Host my-ollama-host
  HostName <your-private-host>
  User <your-ssh-user>
  LocalForward 127.0.0.1:11435 127.0.0.1:11434
```

Start and leave the tunnel running:

```sh
ssh -N -o ExitOnForwardFailure=yes my-ollama-host
```

On the Ollama host, install the default model once:

```sh
ollama pull qwen3.5:9b
```

Verify the endpoint advertises the model before configuring Whisper:

```sh
curl --fail http://127.0.0.1:11435/v1/models
python3 ./scripts/smoke-test-ollama.py
```

The smoke test sends only a short, hard-coded synthetic example. After a Mac reboot, start the SSH tunnel again. Do not bind Ollama to `0.0.0.0` just to avoid using SSH.

## 3. Install the long-recording patch

Install Whisper from Obsidian Community Plugins first, then run:

```sh
./scripts/apply-plugin-patch.sh "$HOME/path/to/Obsidian Vault"
```

The script checks the plugin ID/version and exact unmodified `main.js` checksum, verifies the patch checksum and output checksum, creates a rollback copy, and refuses unknown plugin bundles. For a preview without modifying the vault:

```sh
./scripts/apply-plugin-patch.sh --dry-run "$HOME/path/to/Obsidian Vault"
```

The patch is intentionally tied to Whisper 1.9.1. A plugin update may replace it; do not bypass checksum failures or reapply to a different bundle without reviewing and testing a new patch. Roll back with:

```sh
./scripts/rollback-plugin-patch.sh "$HOME/path/to/Obsidian Vault"
```

## 4. Enable automatic summaries

After the SSH tunnel is running and `/v1/models` lists the requested model:

```sh
python3 ./scripts/configure-summary.py \
  --vault "$HOME/path/to/Obsidian Vault" \
  --model qwen3.5:9b
```

The script verifies the model through the loopback endpoint, backs up the existing plugin settings beside `data.json` with restrictive permissions, and sets the local Whisper endpoint, vault paths, chunk-progress diagnostics, and post-processing options. Its default prompt produces concise but substantive notes that retain salient discussion details, state decisions explicitly, and separate decisions from proposals and open questions. It preserves unrelated settings and keeps the raw transcript. New notes are created under `Inbox/Transcripts`; to use another Ollama model, pass its exact tag with `--model`.

Save open notes and reload Obsidian before recording. Do not reload during an active recording.

## Privacy and repository hygiene

- This repository is public. Never commit secrets, credentials, hostnames, private IPs, or personal data; committed content and history are publicly available and may be mirrored.
- Never commit `.obsidian/plugins/whisper/data.json`, backup settings, `main.js`, audio files, transcripts, logs, SSH config, private IPs, or model weights. `.gitignore` excludes common cases; still inspect `git status` before committing.
- The patch is a small diff against the installed third-party plugin; this repo does not redistribute the full plugin bundle. The patch is derived from `whisper-obsidian-plugin` © 2023 Nik Danilov, MIT; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
- The SSH tunnel is bound to loopback on the Mac and encrypts traffic to the user's SSH host. Transcripts are still transferred to that host for summarization.
