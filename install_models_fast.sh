#!/bin/bash

# ============================================================================
# RunPod Runtime Setup Script - FAST EDITION (GGUF + Distilled)
# ============================================================================
#
# Optimized for Speed:
# - Uses Wan 2.1 I2V GGUF (Q4_K_M) for low VRAM/high speed
# - Uses Distilled LoRA for 4-5 step generation
# - Installs native GGUF support
#
# ============================================================================

set -e  # Exit on error

# GitHub custom nodes are pinned to commits observed on 2026-05-05.
# Do not clone moving branch heads in production images; upstream ComfyUI nodes
# can change validation behavior and break old workflows.
COMFYUI_GGUF_COMMIT="6ea2651e7df66d7585f6ffee804b20e92fb38b8a"
WAN_VIDEO_WRAPPER_COMMIT="d18cdb18597f525ef8d613a0cb447080fbab8fce"
VIDEO_HELPER_SUITE_COMMIT="2984ec4c4b93292421888f38db74a5e8802a8ff8"
FRAME_INTERPOLATION_COMMIT="26545cc2dd95bc3d27f056016300673bdeee78f5"

clone_pinned_repo() {
    local dir="$1"
    local url="$2"
    local commit="$3"

    if [ ! -d "$dir/.git" ]; then
        rm -rf "$dir"
        git clone --no-checkout "$url" "$dir"
    fi

    git -C "$dir" fetch --depth 1 origin "$commit"
    git -C "$dir" checkout --detach "$commit"
}

# ============================================================================
# 1. Detect ComfyUI Directory
# ============================================================================

if [ -d "/ComfyUI" ]; then
    COMFY_DIR="/ComfyUI";
elif [ -d "/workspace/ComfyUI" ]; then
    COMFY_DIR="/workspace/ComfyUI";
elif [ -d "/workspace/runpod-slim/ComfyUI" ]; then
    COMFY_DIR="/workspace/runpod-slim/ComfyUI";
else
    echo "❌ ComfyUI directory not found!";
    exit 1;
fi

echo "✅ Found ComfyUI at: $COMFY_DIR";

# ============================================================================
# 2. Check for Tokens
# ============================================================================

if [ -n "$HF_TOKEN" ]; then
    echo "🔑 Using HuggingFace Token";
    HF_AUTH=(-H "Authorization: Bearer $HF_TOKEN")
else
    echo "⚠️  HF_TOKEN not set! Downloads from gated repos might fail.";
    HF_AUTH=()
fi

if [ -z "$CIVITAI_TOKEN" ]; then
    echo "⚠️  CIVITAI_TOKEN not set!";
    CIVITAI_AUTH=()
else
    echo "🔑 Using CivitAI API Token";
    CIVITAI_AUTH=(-H "Authorization: Bearer $CIVITAI_TOKEN")
fi

# ============================================================================
# 3. Install Custom Nodes
# ============================================================================

echo "";
echo "📦 Installing Custom Nodes...";
mkdir -p "$COMFY_DIR/custom_nodes";
cd "$COMFY_DIR/custom_nodes";

# ComfyUI-GGUF (REQUIRED for GGUF models)
if [ ! -d "ComfyUI-GGUF" ]; then
    echo "  - Installing ComfyUI-GGUF...";
    clone_pinned_repo "ComfyUI-GGUF" "https://github.com/city96/ComfyUI-GGUF.git" "$COMFYUI_GGUF_COMMIT";
    cd ComfyUI-GGUF
    pip install -r requirements.txt
    cd "$COMFY_DIR/custom_nodes"
fi

# Ensure ComfyUI-GGUF dependencies are met (in case of re-run)
if [ -d "ComfyUI-GGUF" ]; then
    clone_pinned_repo "ComfyUI-GGUF" "https://github.com/city96/ComfyUI-GGUF.git" "$COMFYUI_GGUF_COMMIT"
    cd ComfyUI-GGUF
    pip install -r requirements.txt
    cd "$COMFY_DIR/custom_nodes"
fi

# WanVideoWrapper (Required for VAE/TextEnc/Conditioning)
if [ ! -d "ComfyUI-WanVideoWrapper" ]; then
    echo "  - Installing WanVideoWrapper...";
    clone_pinned_repo "ComfyUI-WanVideoWrapper" "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "$WAN_VIDEO_WRAPPER_COMMIT";
fi

# Ensure Wan dependencies
if [ -d "ComfyUI-WanVideoWrapper" ]; then
    clone_pinned_repo "ComfyUI-WanVideoWrapper" "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "$WAN_VIDEO_WRAPPER_COMMIT"
    echo "  - Checking WanVideoWrapper dependencies..."
    cd ComfyUI-WanVideoWrapper
    pip install -r requirements.txt
    cd "$COMFY_DIR/custom_nodes"
fi

# VideoHelperSuite (Required for saving video)
if [ ! -d "ComfyUI-VideoHelperSuite" ]; then
    echo "  - Installing VideoHelperSuite...";
    clone_pinned_repo "ComfyUI-VideoHelperSuite" "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$VIDEO_HELPER_SUITE_COMMIT";
else
    clone_pinned_repo "ComfyUI-VideoHelperSuite" "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$VIDEO_HELPER_SUITE_COMMIT"
fi

## Frame Interpolation (RIFE) - For 30fps smoothness
#if [ ! -d "ComfyUI-Frame-Interpolation" ]; then
#    echo "  - Installing ComfyUI-Frame-Interpolation...";
#    clone_pinned_repo "ComfyUI-Frame-Interpolation" "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git" "$FRAME_INTERPOLATION_COMMIT";
#    cd ComfyUI-Frame-Interpolation && pip install -r requirements.txt && cd ..
#fi

# Ensure critical dependencies for video saving and speed
pip install imageio-ffmpeg sageattention

# ============================================================================
# 4. Download Optimized Models (GGUF + LoRA)
# ============================================================================

echo "";
echo "🚀 Downloading Optimized Models...";

# --- GGUF Model (Wan 2.2) ---
# Maps to models/diffusion_models
mkdir -p "$COMFY_DIR/models/diffusion_models";
cd "$COMFY_DIR/models/diffusion_models";

if [ ! -f "Wan2_2_Animate_14B_Q4_K_M.gguf" ]; then
    echo "  - Downloading Wan 2.2 Animate 14B (Q4_K_M GGUF)...";
    curl -L "${HF_AUTH[@]}" -o Wan2_2_Animate_14B_Q4_K_M.gguf "https://huggingface.co/Kijai/WanVideo_comfy_GGUF/resolve/main/Wan22Animate/Wan2_2_Animate_14B_Q4_K_M.gguf";
else echo "  ✓ Wan 2.2 GGUF (Q4_K_M)"; fi

# --- Turbo LoRA ---
mkdir -p "$COMFY_DIR/models/loras";
cd "$COMFY_DIR/models/loras";

if [ ! -f "Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors" ]; then
    echo "  - Downloading Wan 2.1 Distilled LoRA (Turbo)...";
    curl -L "${HF_AUTH[@]}" -o Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors "https://huggingface.co/lightx2v/Wan2.1-I2V-14B-720P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors";
else echo "  ✓ Wan 2.1 Distilled LoRA"; fi

# --- Support Models (T5, VAE, CLIP Vision) ---
# These are still required for the pipeline

# T5 Text Encoder
mkdir -p "$COMFY_DIR/models/text_encoders";
cd "$COMFY_DIR/models/text_encoders";
if [ ! -f "umt5_xxl_fp8_e4m3fn.safetensors" ]; then
    echo "  - Downloading T5 XXL (fp8)...";
    curl -L "${HF_AUTH[@]}" -o umt5_xxl_fp8_e4m3fn.safetensors "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors";
else echo "  ✓ T5 XXL (fp8)"; fi

# Wan VAE (Wan 2.1 - Compatible with 14B)
mkdir -p "$COMFY_DIR/models/vae/wan";
cd "$COMFY_DIR/models/vae/wan";
if [ ! -f "wan_2.1_vae.safetensors" ]; then
    echo "  - Downloading Wan VAE...";
    curl -L -o wan_2.1_vae.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors";
else echo "  ✓ Wan VAE"; fi

# RIFE VFI Model
mkdir -p "$COMFY_DIR/models/vfi";
cd "$COMFY_DIR/models/vfi";
if [ ! -f "rife47.pth" ]; then
    echo "  - Downloading RIFE 4.7...";
    curl -L "${HF_AUTH[@]}" -o rife47.pth "https://github.com/styler00dollar/VSGAN-tensorrt-docker/releases/download/models/rife47.pth";
else echo "  ✓ RIFE 4.7"; fi

# CLIP Vision
mkdir -p "$COMFY_DIR/models/clip_vision";
cd "$COMFY_DIR/models/clip_vision";
if [ ! -f "clip_vision_h.safetensors" ]; then
    echo "  - Downloading CLIP Vision H...";
    curl -L -o clip_vision_h.safetensors "https://huggingface.co/laion/CLIP-ViT-H-14-laion2B-s32B-b79K/resolve/main/model.safetensors";
else echo "  ✓ CLIP Vision H"; fi

# ============================================================================
# 5. Verify Installation
# ============================================================================

echo "";
echo "════════════════════════════════════════════════════════════════════════";
echo "✅ FAST Setup Complete!";
echo "Please refresh your ComfyUI browser tab.";
echo "════════════════════════════════════════════════════════════════════════";
