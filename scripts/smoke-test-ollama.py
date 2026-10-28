#!/usr/bin/env python3
"""Test local Ollama summarization with synthetic text, never vault content."""
import argparse
import json
import time
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


PROMPT = "Summarize this short sample transcript in one sentence. Return only the summary."
SAMPLE = "We agreed to meet Friday at 10. Maya will send the agenda. The team has not decided whether to invite the vendor."


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ollama-base-url", default="http://127.0.0.1:11435")
    parser.add_argument("--model", default="qwen3.5:9b")
    args = parser.parse_args()
    parsed = urlparse(args.ollama_base_url)
    if parsed.scheme != "http" or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        parser.error("Only a loopback HTTP Ollama endpoint is allowed.")
    base_url = f"{parsed.scheme}://{parsed.netloc}"
    try:
        with urlopen(f"{base_url}/v1/models", timeout=5) as response:
            models = json.load(response).get("data", [])
        ids = {item.get("id") for item in models if isinstance(item, dict)}
        if args.model not in ids:
            parser.error(f"Model {args.model!r} not available; found: {', '.join(sorted(ids)) or '(none)'}")
        payload = {
            "model": args.model,
            "messages": [
                {"role": "system", "content": PROMPT},
                {"role": "user", "content": SAMPLE},
            ],
        }
        request = Request(
            f"{base_url}/v1/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Authorization": "Bearer ollama", "Content-Type": "application/json"},
            method="POST",
        )
        started = time.monotonic()
        with urlopen(request, timeout=180) as response:
            result = json.load(response)
        content = result["choices"][0]["message"]["content"].strip()
        if not content:
            raise RuntimeError("Model returned empty final content")
    except (URLError, TimeoutError, OSError, KeyError, IndexError, TypeError, json.JSONDecodeError, RuntimeError) as exc:
        parser.error(f"Ollama smoke test failed: {exc}")
    print(f"PASS: {args.model} returned a summary in {time.monotonic() - started:.1f}s.")
    print("Synthetic sample only; no vault audio or transcript was sent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
