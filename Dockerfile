# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    openssh-server \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# ── Custom nodes for video generation ────────────────────────────────────
RUN cd /comfyui/custom_nodes && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    git clone https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved.git && \
    git clone https://github.com/kijai/ComfyUI-HunyuanVideoWrapper.git && \
    git clone https://github.com/kijai/ComfyUI-CogVideoXWrapper.git && \
    git clone https://github.com/kijai/ComfyUI-MochiWrapper.git && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git

# Install Python dependencies for custom nodes
RUN cd /comfyui && \
    uv pip install -r custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt || true && \
    uv pip install -r custom_nodes/ComfyUI-HunyuanVideoWrapper/requirements.txt || true && \
    uv pip install -r custom_nodes/ComfyUI-CogVideoXWrapper/requirements.txt || true && \
    uv pip install -r custom_nodes/ComfyUI-MochiWrapper/requirements.txt || true && \
    uv pip install -r custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt || true && \
    uv pip install -r custom_nodes/ComfyUI-KJNodes/requirements.txt || true && \
    uv pip install gguf ftfy

# Pinned transformers version to avoid v5.0.0+ breaking changes in custom nodes
RUN uv pip install "transformers<5.0.0"

# Patch HunyuanVideoWrapper: remove device=device from processor calls
# (LlavaProcessor and CLIPImageProcessor don't accept device kwarg, causes JSON serialization error)
RUN sed -i \
    -e 's/LlavaProcessor.from_pretrained(text_encoder_path, device=device)/LlavaProcessor.from_pretrained(text_encoder_path)/' \
    -e 's/CLIPImageProcessor.from_pretrained(text_encoder_path, device=device)/CLIPImageProcessor.from_pretrained(text_encoder_path)/' \
    /comfyui/custom_nodes/ComfyUI-HunyuanVideoWrapper/hyvideo/text_encoder/__init__.py

# Configure model path to use network volume
ENV COMFYUI_MODEL_PATH=/runpod-volume/models

# Change working directory to ComfyUI
WORKDIR /comfyui

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Fix all dependencies last — uv clobbers packages during earlier installs.
# 1. Reinstall ComfyUI requirements with pip (not uv) to get everything ComfyUI needs
# 2. Reinstall PyTorch CUDA on top (pip won't remove other packages like uv does)
RUN /opt/venv/bin/pip install --no-cache-dir -r /comfyui/requirements.txt && \
    /opt/venv/bin/pip install --no-cache-dir --force-reinstall torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124 && \
    /opt/venv/bin/pip install --no-cache-dir huggingface_hub gguf ftfy diffusers accelerate opencv-python-headless

# Set the default command to run when starting the container
# All models are loaded from the RunPod network volume — nothing baked into the image.
CMD ["/start.sh"]