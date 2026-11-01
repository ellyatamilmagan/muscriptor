# Hugging Face Space version of the original MuScriptor Dockerfile.
# Differences from upstream (everything else is kept identical):
#   * runs as UID 1000 ("user"), which is what Spaces require
#   * listens on port 7860 (Spaces default; README front matter says the same)
#   * no BuildKit cache/bind mounts (plain COPY instead) for builder compatibility
#   * model size is chosen at runtime through the MUSCRIPTOR_MODEL variable

FROM node:22-bookworm-slim AS web-builder
WORKDIR /web

# pnpm is the project's package manager (pinned via package.json#packageManager).
RUN corepack enable

COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY web/ ./
# Analytics stay disabled unless a measurement ID is passed in.
ARG VITE_GA_MEASUREMENT_ID=
ENV VITE_GA_MEASUREMENT_ID=$VITE_GA_MEASUREMENT_ID
# vite outDir is ../muscriptor/web_dist, i.e. /muscriptor/web_dist in this stage.
RUN pnpm run build


FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS runtime

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_FROZEN=1 \
    UV_NO_CACHE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/home/user \
    HF_HOME=/home/user/.cache/huggingface \
    PATH=/app/.venv/bin:$PATH

# fluidsynth: MIDI playback (/auralize). The rest is what the MuseScore
# AppImage needs from the system (sheet-music export).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fluidsynth \
        curl \
        libasound2 \
        libgl1 \
        libegl1 \
        libfontconfig1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Spaces run the container as UID 1000
RUN useradd -m -u 1000 user

WORKDIR /app

ARG MUSESCORE_URL=https://github.com/musescore/MuseScore/releases/download/v4.7.4/MuseScore-Studio-4.7.4.260706075-x86_64.AppImage
RUN curl -fsSL -o /tmp/musescore.AppImage "$MUSESCORE_URL" \
    && chmod +x /tmp/musescore.AppImage \
    && cd /opt && /tmp/musescore.AppImage --appimage-extract > /dev/null \
    && mv squashfs-root musescore \
    && rm /tmp/musescore.AppImage \
    && QT_QPA_PLATFORM=offscreen MU_QT_QPA_PLATFORM=offscreen \
       /opt/musescore/AppRun --version

ENV MUSCRIPTOR_MUSESCORE=/opt/musescore/AppRun

# Python dependencies (cached as long as pyproject.toml / uv.lock don't change)
COPY pyproject.toml uv.lock ./
RUN uv sync --no-install-project

# Pre-fetch the soundfonts into the HF cache of "user" so the first request is fast.
COPY muscriptor/soundfonts.py muscriptor/utils/download.py /tmp/prewarm/
RUN /app/.venv/bin/python -c "\
import sys; sys.path.insert(0, '/tmp/prewarm'); \
import soundfonts, download; \
download.download_if_necessary(soundfonts.SF2_URL); \
download.download_if_necessary(soundfonts.SF3_URL)" \
    && rm -rf /tmp/prewarm

COPY README.md ./
COPY muscriptor/ ./muscriptor/
RUN uv sync

COPY --from=web-builder /muscriptor/web_dist ./muscriptor/web_dist

# everything the runtime user must be able to write (HF cache, MuseScore config, temp files)
RUN mkdir -p /home/user/.cache /home/user/.config \
    && chown -R user:user /home/user \
    && chmod -R a+rX /app /opt/musescore

USER user
WORKDIR /app

EXPOSE 7860

# MUSCRIPTOR_MODEL (Space variable): small | medium | large   (default: small, fits free CPU)
# HF_TOKEN (Space secret) is read automatically by huggingface_hub to download the gated weights.
CMD ["sh", "-c", "exec muscriptor serve --host 0.0.0.0 --port 7860 --model ${MUSCRIPTOR_MODEL:-small}"]
