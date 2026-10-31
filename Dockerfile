# Avalon — Qwen3.8-Flash-Next llama-server, ROCm (AMD RDNA3).
#
# Lean image: only llama-server, the entrypoint, huggingface_hub + python.
# The ~89 GiB model is NOT baked in; the entrypoint downloads it on first
# start into a volume (/models).

# --- build stage: compile llama-server with HIP for RDNA3 ---
FROM docker.io/rocm/dev-ubuntu-24.04:7.2.1-complete AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV AMDGPU_TARGETS="gfx1100;gfx1101;gfx1102"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake git libssl-dev curl libgomp1 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the whole Avalon tree (includes ggml/, gguf-py/, convert scripts...)
COPY . .

# Build just llama-server, Release, HIP backend on. The upstream rocm.Dockerfile
# uses the same flags; we skip the tools/ui web app (not needed for the API).
RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build \
        -DGGML_HIP=ON \
        -DAMDGPU_TARGETS="${AMDGPU_TARGETS}" \
        -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=OFF \
 && cmake --build build --config Release -j"$(nproc)" --target llama-server

RUN mkdir -p /app/lib \
 && find build -name "*.so*" -exec cp -P {} /app/lib \; \
 && cp build/bin/llama-server /app/llama-server

# --- runtime stage ---
FROM docker.io/rocm/dev-ubuntu-24.04:7.2.1-complete AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgomp1 curl python3 python3-pip git \
 && pip3 install --no-cache-dir --break-system-packages \
      "huggingface_hub[cli]" \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/llama-server /app/llama-server
COPY --from=build /app/lib /app/lib
COPY docker/avalon-entrypoint.sh /app/avalon-entrypoint.sh
RUN chmod +x /app/avalon-entrypoint.sh

# Runtime GPU arch detection (rocm-smi not always present; kernel is chosen by
# HIP_VISIBLE_DEVICES / env on the host, plus AMDGPU_TARGETS is baked fat).
ENV AMDGPU_TARGETS="gfx1100;gfx1101;gfx1102"

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=900s --retries=3 \
  CMD curl -fsS http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/avalon-entrypoint.sh"]
