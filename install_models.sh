#!/bin/bash

# ============================================================================
# RunPod Runtime Setup Script
# ============================================================================
# 
# Usage: Copy and paste this into the RunPod Web Terminal
#
# SUPPORTED WORKFLOWS:
# - txt2img: Standard text-to-image generation (Pony/SDXL/Ilustrious)
# - fix-face: Face restoration using FaceDetailer + GFPGAN
# - upscale: 4x upscaling using RealESRGAN
# - face-restore: Face restoration using FaceDetailer + GFPGAN/CodeFormer
#
# ============================================================================

set -e  # Exit on error

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
    if [ -d "custom_nodes" ] && [ -d "models" ]; then
        COMFY_DIR="$(pwd)";
        echo "⚠️  Using current directory: $COMFY_DIR";
    else
        echo "❌ Could not find ComfyUI directory automatically.";
        exit 1;
    fi
fi

echo "✅ Found ComfyUI at: $COMFY_DIR";

# ============================================================================
# 2. Check for Tokens
# ============================================================================

if [ -z "$CIVITAI_TOKEN" ]; then
    echo "⚠️  CIVITAI_TOKEN not set! Downloads may fail for gated/NSFW models.";
    echo "    (Export it with: export CIVITAI_TOKEN=your_token_here)";
    CIVITAI_AUTH=()
else
    echo "🔑 Using CivitAI API Token";
    CIVITAI_AUTH=(-H "Authorization: Bearer $CIVITAI_TOKEN")
fi

if [ -n "$HF_TOKEN" ]; then
    echo "🔑 Using HuggingFace Token";
    HF_AUTH=(-H "Authorization: Bearer $HF_TOKEN")
else
    HF_AUTH=()
fi

# ============================================================================
# 3. Install Custom Nodes
# ============================================================================

echo "";
echo "📦 Installing Custom Nodes...";
cd "$COMFY_DIR/custom_nodes";

# Impact Pack (Required for FaceDetailer)
if [ ! -d "ComfyUI-Impact-Pack" ]; then
    echo "  - Installing Impact Pack...";
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git;
fi

# Always ensure main pack dependencies
if [ -d "ComfyUI-Impact-Pack" ]; then
    echo "  - Checking Impact Pack dependencies..."
    cd ComfyUI-Impact-Pack
    pip install -r requirements.txt
    cd "$COMFY_DIR/custom_nodes"
fi

# Impact Subpack (REQUIRED for UltralyticsDetectorProvider)
if [ ! -d "ComfyUI-Impact-Subpack" ]; then
    echo "  - Installing Impact Subpack (Critical for FaceDetailer)...";
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git;
    cd ComfyUI-Impact-Subpack
    pip install -r requirements.txt
    python3 -m pip install ultralytics opencv-python-headless
    
    # Try to install system dependencies for OpenCV if apt is available
    if command -v apt-get &> /dev/null; then
        echo "  - Checking system libraries..."
        apt-get update && apt-get install -y libgl1 libglib2.0-0 || echo "⚠️ System lib install failed, hoping for the best.";
    fi
    
    cd "$COMFY_DIR/custom_nodes"
else
    echo "  ✓ Impact Subpack already installed."
    # Force deps check
    cd ComfyUI-Impact-Subpack
    pip install -r requirements.txt
    python3 -m pip install ultralytics opencv-python-headless
    
    if command -v apt-get &> /dev/null; then
           apt-get update && apt-get install -y libgl1 libglib2.0-0 || true;
    fi
    
    cd "$COMFY_DIR/custom_nodes"
fi

# Fix Protobuf compatibility (Impact/FaceDetailer)
echo "🔧 Fixing Protobuf compatibility for FaceDetailer..."
pip install "protobuf<5"

# ============================================================================
# 4. Download Checkpoints (txt2img models)
# ============================================================================

echo "";
echo "💾 Downloading Checkpoints...";
cd "$COMFY_DIR/models/checkpoints";

# --- PONY FAMILY ---

# CyberRealistic Pony v14.1 (Default)
if [ ! -f "cyberrealisticPony_v141.safetensors" ]; then
    echo "  - Downloading CyberRealistic Pony (v14.1)...";
    curl -L "${CIVITAI_AUTH[@]}" -o cyberrealisticPony_v141.safetensors "https://civitai.com/api/download/models/2334591";
else echo "  ✓ CyberRealistic Pony v14.1"; fi

# DucHaiten Pony Real v2.0
# if [ ! -f "duchaitenPonyReal_v20.safetensors" ]; then
#     echo "  - Downloading DucHaiten Pony (v2.0)...";
#     curl -L $CIVITAI_AUTH_HEADER -o duchaitenPonyReal_v20.safetensors "https://civitai.com/api/download/models/834838";
# else echo "  ✓ DucHaiten Pony v2.0"; fi

# --- ILUSTRIOUS FAMILY (if available) ---
# TODO: Add Ilustrious model IDs when available

# ============================================================================
# 5. Download LoRAs
# ============================================================================

echo "";
echo "🎨 Downloading LoRAs...";
cd "$COMFY_DIR/models/loras";

declare -a loras=(
    # ExpressiveH (Hentai style) - ID: 382152
    "Expressive_H-000001.safetensors|https://civitai.com/api/download/models/382152"
    # Detail Slider (StS) - ID: 448745
    "StS_detail_slider_v1.safetensors|https://civitai.com/api/download/models/448745"
    # GeekPower AI Styles - ID: 681990
    # "GeekpowerAIStyles_v1.0.safetensors|https://civitai.com/api/download/models/681990"
);

for lora in "${loras[@]}"; do
    IFS="|" read -r name url <<< "$lora";
    if [ ! -f "$name" ]; then
        echo "  - Downloading $name...";
        curl -L "${CIVITAI_AUTH[@]}" -o "$name" "$url";
    else echo "  ✓ $name"; fi
done

# ============================================================================
# 6. Download Upscale Models
# ============================================================================

echo "";
echo "📈 Downloading Upscale Models...";
mkdir -p "$COMFY_DIR/models/upscale_models";
cd "$COMFY_DIR/models/upscale_models";

# RealESRGAN x4 Plus (General purpose 4x upscaler)
if [ ! -f "RealESRGAN_x4plus.pth" ]; then
    echo "  - Downloading RealESRGAN x4 Plus...";
    curl -L -o RealESRGAN_x4plus.pth "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth";
else echo "  ✓ RealESRGAN x4 Plus"; fi

# RealESRGAN x4 Plus Anime (Anime-optimized 4x upscaler)
# if [ ! -f "RealESRGAN_x4plus_anime_6B.pth" ]; then
#     echo "  - Downloading RealESRGAN x4 Plus Anime...";
#     curl -L -o RealESRGAN_x4plus_anime_6B.pth "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth";
# else echo "  ✓ RealESRGAN x4 Plus Anime"; fi

# ============================================================================
# 7. Download Face Restoration Models
# ============================================================================

echo "";
echo "👤 Downloading Face Restoration Models...";

# Ultralytics face detection models (for FaceDetailer)
mkdir -p "$COMFY_DIR/models/ultralytics/bbox";
cd "$COMFY_DIR/models/ultralytics/bbox";

if [ ! -f "face_yolov9c.pt" ]; then
    echo "  - Downloading YOLOv9c Face Detector (Best)...";
    curl -L -o face_yolov9c.pt "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt";
else echo "  ✓ YOLOv9c Face Detector"; fi

# GFPGAN (face restoration)
mkdir -p "$COMFY_DIR/models/facerestore_models";
cd "$COMFY_DIR/models/facerestore_models";

# if [ ! -f "GFPGANv1.4.pth" ]; then
#     echo "  - Downloading GFPGAN v1.4...";
#     curl -L -o GFPGANv1.4.pth "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.4/GFPGANv1.4.pth";
# else echo "  ✓ GFPGAN v1.4"; fi

# CodeFormer (alternative face restoration)
# if [ ! -f "codeformer.pth" ]; then
#     echo "  - Downloading CodeFormer...";
#     curl -L -o codeformer.pth "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth";
# else echo "  ✓ CodeFormer"; fi

# SAM (Segment Anything Model - for FaceDetailer masking)
mkdir -p "$COMFY_DIR/models/sams";
cd "$COMFY_DIR/models/sams";

if [ ! -f "sam_vit_b_01ec64.pth" ]; then
    echo "  - Downloading SAM ViT-B...";
    curl -L -o sam_vit_b_01ec64.pth "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth";
else echo "  ✓ SAM ViT-B"; fi

# ============================================================================
# 8. Verify Installation
# ============================================================================

echo "";
echo "════════════════════════════════════════════════════════════════════════";
echo "✅ Setup Complete!";
echo "";
echo "Installed Components:";
echo "  📁 Checkpoints: $(ls -1 "$COMFY_DIR/models/checkpoints" 2>/dev/null | wc -l) files";
echo "  🎨 LoRAs: $(ls -1 "$COMFY_DIR/models/loras" 2>/dev/null | wc -l) files";
echo "  📈 Upscalers: $(ls -1 "$COMFY_DIR/models/upscale_models" 2>/dev/null | wc -l) files";
echo "  👤 Face Models: $(ls -1 "$COMFY_DIR/models/facerestore_models" 2>/dev/null | wc -l) files";
echo "";
echo "Please refresh your ComfyUI browser tab to see the new models.";
echo "════════════════════════════════════════════════════════════════════════";
