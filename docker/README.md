# Avalon ROCm image — usage notes

Builds a lean `llama-server` container for Qwen3.8-Flash-Next (with MTP
speculative decoding), compiled with ROCm for AMD RDNA3 (gfx1100/1101/1102).
The model is **not** baked into the image: the entrypoint downloads it from
HuggingFace on first start into a mounted volume.

## Image

`ghcr.io/madejackson/avalon:latest` (also tagged `rocm`).

## Host requirements

- AMD RDNA3 GPU (RX 7900 XT/XTX etc.) with the **amdgpu** kernel driver
  (`/dev/kfd`, `/dev/dri/card*` present).
- Docker 24+ (device passthrough). No ROCm install needed on the host.

## Run

```bash
docker run -d --name avalon \
  --device /dev/kfd:/dev/kfd \
  --device /dev/dri:/dev/dri \
  -p 8080:8080 \
  -v /data/avalon_models:/models \
  -e AVALON_MODEL_REPO=freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF \
  -e HOST=0.0.0.0 -e PORT=8080 \
  -e API_KEY=secret \
  ghcr.io/madejackson/avalon:latest
```

First start downloads ~89 GiB (33 shards + MTP draft head) and verifies
SHA-256 of every file; allow up to an hour on fast links. Afterwards the model
is cached in `/models` (resume-safe).

## Config

| Env | Default | Meaning |
|-----|---------|---------|
| `AVALON_MODEL_REPO` | `freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF` | HF repo to pull |
| `AVALON_MODEL_DIR` | `/models` | Model cache dir (mount a volume) |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Port |
| `API_KEY` | _(unset)_ | Required bearer token when set |

Server flags are the MTP ones from the Avalon README (`-md` draft head,
`--spec-type draft-mtp`, etc.); pass extras via command arguments

## Verify

```bash
curl -fsS http://localhost:8080/health
curl -s http://localhost:8080/v1/models
```

## Notes

- The image is compiled with `GGML_HIP=ON`, `AMDGPU_TARGETS=gfx1100;gfx1101;gfx1102`,
  Release, CPU-all-variants + LLAMA_BACKEND_DL so CPU fallback also works.
- To avoid rebuilds for the web UI, only the server is shipped; the HF repo
  already contains a 89 GiB model that fits in context of the server only.