#!/usr/bin/env bash
# Avalon container entrypoint.
#
# Downloads the Qwen3.8-Flash-Next GGUF (with MTP draft head) from HuggingFace
# on first start (~89 GiB, resumable), verifies every file's SHA-256 against
# the repo's lfs hashes, then runs llama-server with the flags the Avalon
# README uses for MTP speculative decoding.
#
# Environment:
#   AVALON_MODEL_REPO  HF repo (default freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)
#   AVALON_MODEL_DIR   where to keep the model (default /models)
#   HOST / PORT        bind address / port (default 0.0.0.0:8080)
#   API_KEY            if set, llama-server requires it (Authorization: Bearer)
#   HF_HUB_DISABLE_TELEMETRY=1 to silence hf transfers
set -euo pipefail

MODEL_REPO="${AVALON_MODEL_REPO:-freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF}"
MODEL_DIR="${AVALON_MODEL_DIR:-/models}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

# helpers
log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

download_model() {
  # --local-dir downloads full files with .cache/huggingface-style locking and
  # resume support. We exclude nothing: the repo has no jpg/md lfs files, but
  # needing the exact IQ3_K_S shard + MTP head, we take everything.
  log "Downloading model from hf.co/$MODEL_REPO into $MODEL_DIR (first start, ~89 GiB, resumable)"
  HF_HUB_DISABLE_TELEMETRY=1 huggingface-cli download \
    "$MODEL_REPO" \
    --local-dir "$MODEL_DIR" \
    --local-dir-use-symlinks False || return 1

  log "Verifying SHA-256 of every file"
  python3 - "$MODEL_REPO" "$MODEL_DIR" <<'PY'
import hashlib, json, os, sys, urllib.request, concurrent.futures

repo, root = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true") as r:
    tree = json.load(r)
files = [(f["path"], f["lfs"]["oid"], f["size"]) for f in tree if f["type"] == "file" and f.get("lfs")]

bad = []
def check(item):
    path, oid, size = item
    p = os.path.join(root, path)
    if not os.path.exists(p) or os.path.getsize(p) != size:
        return path, "missing or wrong size"
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return (path, "sha256 mismatch") if h.hexdigest() != oid else (None, None)

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    for path, err in ex.map(check, files):
        if err:
            bad.append((path, err))
if bad:
    for p, e in bad:
        print(f"  {p}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"  {len(files)} files OK")
PY
}

# The model repo contains the IQ3_K_S split into 33 shards
# (Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf) plus the MTP draft
# (mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf).
MODEL_FILE="Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf"
MTP_FILE="mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf"

if [ ! -f "$MODEL_DIR/$MODEL_FILE" ]; then
  export PATH="$PATH:/usr/local/bin"
  command -v huggingface-cli >/dev/null || die "huggingface-cli not found in image"
  download_model
fi

[ -f "$MODEL_DIR/$MODEL_FILE" ] || die "model file missing after download: $MODEL_FILE"
[ -f "$MODEL_DIR/$MTP_FILE" ] || die "MTP draft file missing: $MTP_FILE"

log "Model ready. Starting llama-server on http://$HOST:$PORT"

args=(
  -m "$MODEL_DIR/$MODEL_FILE"
  -c 262144
  -b 9536
  -ub 9536
  -fa on
  -ctk q8_0
  -ctv q4_0
  --jinja
  --parallel 1
  -md "$MODEL_DIR/$MTP_FILE"
  --spec-type draft-mtp
  --spec-draft-n-max 2
  -ubd 256
  -ctkd q8_0
  -ctvd q8_0
  --host "$HOST"
  --port "$PORT"
)
if [ -n "${API_KEY:-}" ]; then
  args+=(--api-key "$API_KEY")
fi

exec /app/llama-server "${args[@]}" "$@"
