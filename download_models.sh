#!/bin/bash

# Stable Diffusion WebUI Model Download Script
# Run this from Jupyter terminal

set +e  # Continue on errors

# Base paths
BASE_PATH="/workspace/stable-diffusion-webui-forge"
MODELS_PATH="${BASE_PATH}/models"
EXTENSIONS_PATH="${BASE_PATH}/extensions"

# API Keys (optional but recommended)
CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
FAILED=0
SUCCESS=0
SKIPPED=0

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    ((SUCCESS++))
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    ((FAILED++))
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_skip() {
    echo -e "${YELLOW}↷ $1${NC}"
    ((SKIPPED++))
}

# Create directory if it doesn't exist
ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1" 2>/dev/null
        if [ $? -eq 0 ]; then
            print_info "Created directory: $1"
        else
            print_error "Failed to create: $1"
            return 1
        fi
    fi
    return 0
}

# Download from Hugging Face
download_hf() {
    local url="$1"
    local dest="$2"
    
    ensure_dir "$dest" || return 1
    
    local filename=$(basename "$url")
    local filepath="${dest}/${filename}"
    
    if [ -f "$filepath" ]; then
        print_skip "File exists: $filename"
        return 0
    fi
    
    print_info "Downloading: $filename"
    
    local wget_opts="-q --show-progress --timeout=60 --tries=3"
    if [ -n "$HUGGINGFACE_TOKEN" ]; then
        wget_opts="$wget_opts --header='Authorization: Bearer $HUGGINGFACE_TOKEN'"
    fi
    
    if eval "wget $wget_opts '$url' -O '$filepath' 2>/dev/null"; then
        if [ -s "$filepath" ]; then
            print_success "Downloaded: $filename"
            return 0
        fi
    fi
    
    print_error "Failed to download: $filename"
    rm -f "$filepath" 2>/dev/null
    return 1
}

# Download from Civitai with proper naming
download_civitai() {
    local url="$1"
    local dest="$2"
    
    ensure_dir "$dest" || return 1
    
    # Extract model ID
    local model_id=""
    if [[ "$url" =~ models/([0-9]+) ]]; then
        model_id="${BASH_REMATCH[1]}"
    fi
    
    if [ -z "$model_id" ]; then
        print_error "Could not extract model ID from: $url"
        return 1
    fi
    
    # Determine file extension from URL
    local ext="safetensors"
    if [[ "$url" == *"format=SafeTensor"* ]]; then
        ext="safetensors"
    elif [[ "$url" == *"format=PickleTensor"* ]]; then
        ext="ckpt"
    elif [[ "$url" == *"format=Other"* ]]; then
        ext="bin"
    elif [[ "$url" == *"format=Archive"* ]]; then
        ext="zip"
    elif [[ "$url" == *".pt"* ]]; then
        ext="pt"
    fi
    
    # Try to get model name from API
    local model_name=""
    local api_url="https://civitai.com/api/v1/models/${model_id}"
    local api_cmd="curl -s"
    
    if [ -n "$CIVITAI_API_KEY" ]; then
        api_cmd="$api_cmd -H 'Authorization: Bearer $CIVITAI_API_KEY'"
    fi
    
    local api_response=$(eval "$api_cmd '$api_url'" 2>/dev/null)
    
    if [ -n "$api_response" ] && [ "$api_response" != "null" ]; then
        # Try to get model name
        model_name=$(echo "$api_response" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//' | sed 's/"//g' 2>/dev/null)
        # Clean model name
        if [ -n "$model_name" ]; then
            model_name=$(echo "$model_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
        fi
    fi
    
    # Build filename
    local filename=""
    if [ -n "$model_name" ]; then
        filename="${model_name}.${ext}"
    else
        filename="${model_id}.${ext}"
    fi
    
    local filepath="${dest}/${filename}"
    
    if [ -f "$filepath" ]; then
        print_skip "File exists: $filename"
        return 0
    fi
    
    print_info "Model ID: $model_id"
    print_info "Downloading: $filename"
    
    # Download the file
    local wget_opts="-q --show-progress --timeout=60 --tries=3"
    if [ -n "$CIVITAI_API_KEY" ]; then
        wget_opts="$wget_opts --header='Authorization: Bearer $CIVITAI_API_KEY'"
    fi
    
    if eval "wget $wget_opts '$url' -O '$filepath' 2>/dev/null"; then
        if [ -s "$filepath" ]; then
            print_success "Downloaded: $filename"
            
            # Save metadata if available
            if [ -n "$api_response" ] && [ "$api_response" != "null" ]; then
                echo "$api_response" > "${dest}/${filename%.*}_metadata.json" 2>/dev/null
            fi
            return 0
        fi
    fi
    
    print_error "Failed to download: $filename"
    rm -f "$filepath" 2>/dev/null
    return 1
}

# Clone git extension
clone_extension() {
    local repo="$1"
    local name=$(basename "$repo" .git)
    local target="${EXTENSIONS_PATH}/${name}"
    
    if [ -d "$target" ]; then
        print_skip "Extension exists: $name"
        return 0
    fi
    
    print_info "Cloning: $name"
    if git clone "$repo" "$target" 2>/dev/null; then
        print_success "Cloned: $name"
        return 0
    else
        print_error "Failed to clone: $name"
        return 1
    fi
}

# Main execution
main() {
    print_header "Stable Diffusion WebUI Download Script"
    echo "Started at: $(date)"
    echo ""
    
    # Show API key status
    if [ -n "$CIVITAI_API_KEY" ]; then
        print_info "Civitai API key: Set ✓"
    else
        print_info "Civitai API key: Not set (some downloads may fail)"
        print_info "Set with: export CIVITAI_API_KEY='your_key'"
    fi
    
    if [ -n "$HUGGINGFACE_TOKEN" ]; then
        print_info "Hugging Face token: Set ✓"
    else
        print_info "Hugging Face token: Not set (some downloads may fail)"
        print_info "Set with: export HUGGINGFACE_TOKEN='your_token'"
    fi
    echo ""
    
    # Create base directory
    ensure_dir "$BASE_PATH" || exit 1
    
    # Create model directories
    print_header "Creating Directories"
    for dir in ControlNet ControlNetPreprocessor diffusers embeddings ESRGAN Lora Stable-diffusion VAE adetailer; do
        ensure_dir "${MODELS_PATH}/${dir}"
    done
    
    # Clone Extensions
    print_header "Cloning Extensions"
    for repo in \
        "https://github.com/altoiddealer/--sd-webui-ar-plusplus.git" \
        "https://github.com/eduardoabreu81/sd-webui-tagcomplete-neo.git" \
        "https://github.com/abzaloff/aadetailer-neoforge.git" \
        "https://github.com/eduardoabreu81/sd-civitai-browser-neo.git" \
        "https://github.com/Haoming02/sd-forge-couple.git" \
        "https://github.com/Haoming02/sd-forge-nvidia-vfx.git" \
        "https://github.com/Panchovix/reForge-Sigmas_merge.git" \
        "https://github.com/Dusky-dev/sd-forge_neo-infinite-image-browsing-xl.git" \
        "https://github.com/hnmr293/sd-webui-cutoff.git" \
        "https://github.com/hako-mikan/sd-webui-cd-tuner.git" \
        "https://github.com/shirayu/sd-webui-enable-checker.git" \
        "https://github.com/hirorohi03/sd-webui-forge-spectrum.git" \
        "https://github.com/Haoming02/sd-forge-negpip.git" \
        "https://github.com/Haoming02/sd-webui-resharpen.git" \
        "https://github.com/Haoming02/sd-webui-tabs-extension.git" \
        "https://github.com/light-and-ray/sd-webui-yandere-inpaint-masked-content.git" \
        "https://github.com/Replactionap/Stable-Diffusion-Webui-Civitai-Helper-RED-UPDATE.git" \
        "https://github.com/yamosin/seedvr2-webui-neo-extension.git" \
        "https://github.com/SiliconeShojo/ScribeNEO.git"; do
        clone_extension "$repo"
    done
    
    # Download Models
    print_header "Downloading Models"
    
    # VAE
    echo -e "\n${BLUE}VAE:${NC}"
    download_civitai "https://civitai.red/api/download/models/648388?fileId=824329" "${MODELS_PATH}/VAE"
    
    # Embeddings
    echo -e "\n${BLUE}Embeddings:${NC}"
    download_civitai "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor" "${MODELS_PATH}/embeddings"
    download_civitai "https://civitai.com/api/download/models/2121199?type=Model&format=Other" "${MODELS_PATH}/embeddings"
    download_civitai "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor" "${MODELS_PATH}/embeddings"
    
    # Upscalers
    echo -e "\n${BLUE}Upscalers:${NC}"
    download_civitai "https://civitai.red/api/download/models/164821?fileId=2037845" "${MODELS_PATH}/ESRGAN"
    download_civitai "https://civitai.red/api/download/models/2674200?fileId=2560903" "${MODELS_PATH}/ESRGAN"
    download_civitai "https://civitai.red/api/download/models/729727?fileId=643878" "${MODELS_PATH}/ESRGAN"
    
    # Adetailer
    echo -e "\n${BLUE}Adetailer:${NC}"
    download_civitai "https://civitai.com/api/download/models/176512" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.com/api/download/models/2509406?type=Model&format=PickleTensor" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.com/api/download/models/168820?type=Archive&format=Other" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.com/api/download/models/1780243?type=Archive&format=Other" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.com/api/download/models/235730?type=Archive&format=Other" "${MODELS_PATH}/adetailer"
    download_hf "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt" "${MODELS_PATH}/adetailer"
    download_hf "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.red/api/download/models/465360?fileId=384289" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.red/api/download/models/582139?fileId=497510" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.red/api/download/models/2038997?fileId=1935916" "${MODELS_PATH}/adetailer"
    download_civitai "https://civitai.red/api/download/models/2350456?fileId=2240838" "${MODELS_PATH}/adetailer"
    
    # Checkpoint
    echo -e "\n${BLUE}Checkpoint:${NC}"
    download_civitai "https://civitai.red/api/download/models/2883731?fileId=2763986" "${MODELS_PATH}/Stable-diffusion"
    
    # LoRA
    echo -e "\n${BLUE}LoRAs:${NC}"
    download_civitai "https://civitai.red/api/download/models/2579082?fileId=2466259" "${MODELS_PATH}/Lora"
    download_civitai "https://civitai.red/api/download/models/2177579?fileId=2070697" "${MODELS_PATH}/Lora"
    download_civitai "https://civitai.red/api/download/models/2154919?fileId=2048262" "${MODELS_PATH}/Lora"
    download_civitai "https://civitai.red/api/download/models/1905807?fileId=1804867" "${MODELS_PATH}/Lora"
    download_civitai "https://civitai.red/api/download/models/2979435?fileId=2866837" "${MODELS_PATH}/Lora"
    
    # ControlNet
    echo -e "\n${BLUE}ControlNet:${NC}"
    download_hf "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_depth_mid.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/t2i-adapter_diffusers_xl_lineart.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/thibaud_xl_openpose_256lora.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_canny_mid.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/destitech/controlnet-inpaint-dreamer-sdxl/resolve/main/v2/diffusion_pytorch_model.fp16.safetensors" "${MODELS_PATH}/ControlNet"
    download_civitai "https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet.safetensors" "${MODELS_PATH}/ControlNet"
    download_hf "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet_10w.safetensors" "${MODELS_PATH}/ControlNet"
    download_civitai "https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32" "${MODELS_PATH}/ControlNet"
    
    # Summary
    print_header "Download Complete"
    echo "Finished at: $(date)"
    echo ""
    echo -e "${GREEN}Successfully downloaded: $SUCCESS${NC}"
    echo -e "${YELLOW}Skipped (already exist): $SKIPPED${NC}"
    echo -e "${RED}Failed: $FAILED${NC}"
    echo ""
    echo -e "${BLUE}Total time: $(($SECONDS / 60))m $(($SECONDS % 60))s${NC}"
    
    if [ $FAILED -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Some downloads failed. Possible issues:${NC}"
        echo -e "${YELLOW}- Check your internet connection${NC}"
        echo -e "${YELLOW}- Set API keys: export CIVITAI_API_KEY='your_key'${NC}"
        echo -e "${YELLOW}- Set token: export HUGGINGFACE_TOKEN='your_token'${NC}"
        echo -e "${YELLOW}- Run script again with: ./download_models.sh${NC}"
        exit 1
    else
        echo -e "${GREEN}All downloads completed successfully!${NC}"
        exit 0
    fi
}

# Run main
main "$@"
