#!/bin/bash
set -eo pipefail  # Exit on error, catch pipe failures

# ============================================
# CONFIGURATION - Adjust these paths
# ============================================
WORKSPACE="/workspace"
WEBUI_DIR="${WORKSPACE}/forge"  # or "comfyui" depending on what you use

# Define directories (matches your notebook structure)
EXTENSIONS="${WEBUI_DIR}/extensions"
VAE_DIR="${WEBUI_DIR}/models/VAE"
EMBEDDINGS_DIR="${WEBUI_DIR}/embeddings"
UPSCALERS_DIR="${WEBUI_DIR}/models/ESRGAN"
ADETAILER_DIR="${WEBUI_DIR}/models/adetailer"
CKPT_DIR="${WEBUI_DIR}/models/Stable-diffusion"
LORA_DIR="${WEBUI_DIR}/models/Lora"
CONTROLNET_DIR="${WEBUI_DIR}/models/ControlNet"

# ============================================
# DOWNLOAD FUNCTION (replaces %download)
# ============================================
download_file() {
    local url="$1"
    local output_dir="$2"
    local filename="$3"
    
    # Create directory if it doesn't exist
    mkdir -p "$output_dir"
    
    # If filename not provided, extract from URL
    if [ -z "$filename" ]; then
        # Try to get filename from URL
        filename=$(basename "$url" | cut -d'?' -f1)
        # If no filename, generate one from content-disposition or use timestamp
        if [ -z "$filename" ] || [ "$filename" = "download" ]; then
            filename="downloaded_$(date +%s)"
        fi
    fi
    
    local output_path="${output_dir}/${filename}"
    
    echo "📥 Downloading: $url"
    echo "   → $output_path"
    
    # Use wget with retry and continue
    wget -q --show-progress --timeout=30 --tries=3 -O "$output_path" "$url" || {
        echo "❌ Failed to download: $url"
        return 1
    }
    
    echo "✅ Downloaded: $filename"
}

# ============================================
# CLONE FUNCTION (replaces %cd + !git clone)
# ============================================
clone_repo() {
    local repo_url="$1"
    local target_dir="$2"
    
    # Extract repo name from URL
    local repo_name=$(basename "$repo_url" .git)
    
    # If no target_dir specified, use repo_name
    if [ -z "$target_dir" ]; then
        target_dir="${EXTENSIONS}/${repo_name}"
    fi
    
    echo "📦 Cloning: $repo_url"
    echo "   → $target_dir"
    
    # Remove directory if exists (for fresh clone)
    if [ -d "$target_dir" ]; then
        echo "   ⚠️  Directory exists, pulling latest..."
        cd "$target_dir" && git pull || {
            echo "   ⚠️  Git pull failed, removing and re-cloning..."
            cd "$WORKSPACE" && rm -rf "$target_dir"
            git clone "$repo_url" "$target_dir"
        }
    else
        git clone "$repo_url" "$target_dir"
    fi
    
    echo "✅ Cloned: $repo_name"
}

# ============================================
# MAIN SETUP
# ============================================
echo "🚀 Starting PROVISIONING_SCRIPT..."
echo "⏰ Started at: $(date)"

# Create workspace if it doesn't exist
mkdir -p "$WORKSPACE"

# Check if WebUI directory exists
if [ ! -d "$WEBUI_DIR" ]; then
    echo "❌ WebUI directory not found at: $WEBUI_DIR"
    echo "   Please ensure your base image has Forge/ComfyUI installed"
    echo "   Or clone it here with:"
    echo "   git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git $WEBUI_DIR"
    exit 1
fi

cd "$WEBUI_DIR"

# ============================================
# 1. INSTALL EXTENSIONS
# ============================================
echo "📦 Installing Extensions..."
mkdir -p "$EXTENSIONS"
cd "$EXTENSIONS"

# Clone all extensions
clone_repo "https://github.com/altoiddealer/sd-webui-ar-plusplus.git"
clone_repo "https://github.com/eduardoabreu81/sd-webui-tagcomplete-neo.git"
clone_repo "https://github.com/abzaloff/aadetailer-neoforge.git"
clone_repo "https://github.com/eduardoabreu81/sd-civitai-browser-neo.git"
clone_repo "https://github.com/Haoming02/sd-forge-couple.git"
clone_repo "https://github.com/Haoming02/sd-forge-nvidia-vfx.git"
clone_repo "https://github.com/Panchovix/reForge-Sigmas_merge.git"
clone_repo "https://github.com/Dusky-dev/sd-forge_neo-infinite-image-browsing-xl.git"
clone_repo "https://github.com/hnmr293/sd-webui-cutoff.git"
clone_repo "https://github.com/hako-mikan/sd-webui-cd-tuner.git"
clone_repo "https://github.com/shirayu/sd-webui-enable-checker.git"
clone_repo "https://github.com/hirorohi03/sd-webui-forge-spectrum.git"
clone_repo "https://github.com/Haoming02/sd-forge-negpip.git"
clone_repo "https://github.com/Haoming02/sd-webui-resharpen.git"
clone_repo "https://github.com/Haoming02/sd-webui-tabs-extension.git"
clone_repo "https://github.com/light-and-ray/sd-webui-yandere-inpaint-masked-content.git"
clone_repo "https://github.com/Replactionap/Stable-Diffusion-Webui-Civitai-Helper-RED-UPDATE.git"
clone_repo "https://github.com/yamosin/seedvr2-webui-neo-extension.git"
clone_repo "https://github.com/SiliconeShojo/ScribeNEO.git"

# Return to WebUI directory
cd "$WEBUI_DIR"

# ============================================
# 2. DOWNLOAD VAEs
# ============================================
echo "📥 Downloading VAEs..."
download_file "https://civitai.red/api/download/models/648388?fileId=824329" "$VAE_DIR" "vae_model.safetensors"

# ============================================
# 3. DOWNLOAD EMBEDDINGS
# ============================================
echo "📥 Downloading Embeddings..."
download_file "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor" "$EMBEDDINGS_DIR"
download_file "https://civitai.com/api/download/models/2121199?type=Model&format=Other" "$EMBEDDINGS_DIR"
download_file "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor" "$EMBEDDINGS_DIR"

# ============================================
# 4. DOWNLOAD UPSCALERS
# ============================================
echo "📥 Downloading Upscalers..."
download_file "https://civitai.red/api/download/models/164821?fileId=2037845" "$UPSCALERS_DIR"
download_file "https://civitai.red/api/download/models/2674200?fileId=2560903" "$UPSCALERS_DIR"
download_file "https://civitai.red/api/download/models/729727?fileId=643878" "$UPSCALERS_DIR"

# ============================================
# 5. DOWNLOAD ADETAILER MODELS
# ============================================
echo "📥 Downloading Adetailer Models..."
download_file "https://civitai.com/api/download/models/176512" "$ADETAILER_DIR" "adetailer_1.safetensors"
download_file "https://civitai.com/api/download/models/2509406?type=Model&format=PickleTensor" "$ADETAILER_DIR" "adetailer_2.pt"
download_file "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor" "$ADETAILER_DIR" "adetailer_3.pt"
download_file "https://civitai.com/api/download/models/168820?type=Archive&format=Other" "$ADETAILER_DIR" "adetailer_4.zip"
download_file "https://civitai.com/api/download/models/1780243?type=Archive&format=Other" "$ADETAILER_DIR" "adetailer_5.zip"
download_file "https://civitai.com/api/download/models/235730?type=Archive&format=Other" "$ADETAILER_DIR" "adetailer_6.zip"
download_file "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt" "$ADETAILER_DIR" "face_yolov9c.pt"
download_file "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt" "$ADETAILER_DIR" "hand_yolov9c.pt"
download_file "https://civitai.red/api/download/models/465360?fileId=384289" "$ADETAILER_DIR" "adetailer_7.safetensors"
download_file "https://civitai.red/api/download/models/582139?fileId=497510" "$ADETAILER_DIR" "adetailer_8.safetensors"
download_file "https://civitai.red/api/download/models/2038997?fileId=1935916" "$ADETAILER_DIR" "adetailer_9.safetensors"
download_file "https://civitai.red/api/download/models/2350456?fileId=2240838" "$ADETAILER_DIR" "adetailer_10.safetensors"

# ============================================
# 6. DOWNLOAD CHECKPOINT
# ============================================
echo "📥 Downloading Checkpoint..."
download_file "https://civitai.red/api/download/models/2883731?fileId=2763986" "$CKPT_DIR" "checkpoint.safetensors"

# ============================================
# 7. DOWNLOAD LORAS
# ============================================
echo "📥 Downloading LoRAs..."
download_file "https://civitai.red/api/download/models/2579082?fileId=2466259" "$LORA_DIR" "lora_1.safetensors"
download_file "https://civitai.red/api/download/models/2177579?fileId=2070697" "$LORA_DIR" "lora_2.safetensors"
download_file "https://civitai.red/api/download/models/2154919?fileId=2048262" "$LORA_DIR" "lora_3.safetensors"
download_file "https://civitai.red/api/download/models/1905807?fileId=1804867" "$LORA_DIR" "lora_4.safetensors"
download_file "https://civitai.red/api/download/models/2979435?fileId=2866837" "$LORA_DIR" "lora_5.safetensors"

# ============================================
# 8. DOWNLOAD CONTROLNET MODELS
# ============================================
echo "📥 Downloading ControlNet Models..."
download_file "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth" "$CONTROLNET_DIR" "ip-adapter_xl.pth"
download_file "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_depth_mid.safetensors" "$CONTROLNET_DIR" "diffusers_xl_depth_mid.safetensors"
download_file "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors" "$CONTROLNET_DIR" "kohya_controllllite_xl_openpose_anime_v2.safetensors"
download_file "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/t2i-adapter_diffusers_xl_lineart.safetensors" "$CONTROLNET_DIR" "t2i-adapter_diffusers_xl_lineart.safetensors"
download_file "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/thibaud_xl_openpose_256lora.safetensors" "$CONTROLNET_DIR" "thibaud_xl_openpose_256lora.safetensors"
download_file "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_canny_mid.safetensors" "$CONTROLNET_DIR" "diffusers_xl_canny_mid.safetensors"
download_file "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "$CONTROLNET_DIR" "controlnet-union-sdxl-1.0.safetensors"
download_file "https://huggingface.co/destitech/controlnet-inpaint-dreamer-sdxl/resolve/main/v2/diffusion_pytorch_model.fp16.safetensors" "$CONTROLNET_DIR" "controlnet-inpaint-dreamer-sdxl.fp16.safetensors"
download_file "https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor" "$CONTROLNET_DIR" "controlnet_civitai.safetensors"
download_file "https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors" "$CONTROLNET_DIR" "Kataragi_inpaintXL-fp16.safetensors"
download_file "https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors" "$CONTROLNET_DIR" "controlnet-tile-sdxl.safetensors"
download_file "https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors" "$CONTROLNET_DIR" "noob-sdxl-controlnet-tile.safetensors"
download_file "https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors" "$CONTROLNET_DIR" "illustrious-xl-openpose.safetensors"
download_file "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet.safetensors" "$CONTROLNET_DIR" "illustriousXL_tile_controlnet.safetensors"
download_file "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet_10w.safetensors" "$CONTROLNET_DIR" "illustriousXL_tile_controlnet_10w.safetensors"
download_file "https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32" "$CONTROLNET_DIR" "controlnet_1284707.safetensors"

# ============================================
# 9. INSTALL EXTENSION DEPENDENCIES
# ============================================
echo "📦 Installing Python dependencies for extensions..."
cd "$WEBUI_DIR"

# Run the WebUI's dependency installer (if it exists)
if [ -f "launch.py" ]; then
    echo "🔄 Running WebUI dependency installer..."
    python launch.py --skip-torch-cuda-test --exit || true
fi

# ============================================
# 10. SETUP COMPLETE
# ============================================
echo ""
echo "✅ PROVISIONING_SCRIPT COMPLETED SUCCESSFULLY!"
echo "⏰ Finished at: $(date)"
echo ""
echo "📊 Summary:"
echo "   - $(ls -1 $EXTENSIONS | wc -l) extensions installed"
echo "   - $(ls -1 $CKPT_DIR 2>/dev/null | wc -l) checkpoints"
echo "   - $(ls -1 $LORA_DIR 2>/dev/null | wc -l) LoRAs"
echo "   - $(ls -1 $CONTROLNET_DIR 2>/dev/null | wc -l) ControlNet models"
echo ""
echo "🌐 To start the WebUI, run:"
echo "   cd $WEBUI_DIR && python launch.py --listen --port 8080"
