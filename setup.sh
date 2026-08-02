#!/bin/bash

# Stable Diffusion WebUI Model Download Script
# Run this from Jupyter terminal

# Base paths
BASE_PATH="/workspace/stable-diffusion-webui-forge"
MODELS_PATH="${BASE_PATH}/models"
EXTENSIONS_PATH="${BASE_PATH}/extensions"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counter for failures
FAILED_COUNT=0
SUCCESS_COUNT=0
SKIPPED_COUNT=0

# Function to print colored output
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    ((SUCCESS_COUNT++))
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    ((FAILED_COUNT++))
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_skip() {
    echo -e "${YELLOW}↷ $1${NC}"
    ((SKIPPED_COUNT++))
}

# Function to download file with wget - continues on failure
download_file() {
    local url="$1"
    local destination="$2"
    local filename="$3"
    
    # Create destination directory if it doesn't exist
    mkdir -p "$destination" || {
        print_error "Failed to create directory: $destination"
        return 1
    }
    
    # Determine filename
    if [ -z "$filename" ]; then
        filename=$(basename "${url%%\?*}")
        # If filename is empty or just a hash, generate from URL
        if [ -z "$filename" ] || [ "$filename" = "download" ] || [ "$filename" = "download" ]; then
            filename=$(echo "$url" | md5sum | cut -d' ' -f1)
        fi
    fi
    
    local filepath="${destination}/${filename}"
    
    # Check if file already exists
    if [ -f "$filepath" ]; then
        print_skip "File already exists: $filename"
        return 0
    fi
    
    print_info "Downloading: $filename"
    print_info "From: $url"
    print_info "To: $filepath"
    
    # Download with wget, following redirects - continue on failure
    if wget -q --show-progress --progress=bar:force:noscroll --content-disposition --timeout=30 --tries=3 "$url" -O "$filepath" 2>/dev/null; then
        print_success "Downloaded: $filename"
        return 0
    else
        print_error "Failed to download: $filename"
        # Remove partial file if it exists
        rm -f "$filepath" 2>/dev/null
        return 1
    fi
}

# Function to clone git repository - continues on failure
clone_extension() {
    local repo_url="$1"
    local repo_name=$(basename "$repo_url" .git)
    local target_path="${EXTENSIONS_PATH}/${repo_name}"
    
    if [ -d "$target_path" ]; then
        print_skip "Extension already exists: $repo_name"
        (cd "$target_path" && git pull 2>/dev/null || print_error "Failed to pull latest for $repo_name")
        return 0
    fi
    
    print_info "Cloning: $repo_name"
    if git clone "$repo_url" "$target_path" 2>/dev/null; then
        print_success "Cloned: $repo_name"
        return 0
    else
        print_error "Failed to clone: $repo_name"
        # Remove partial clone if it exists
        rm -rf "$target_path" 2>/dev/null
        return 1
    fi
}

# Main execution
main() {
    print_header "Starting Stable Diffusion WebUI Setup"
    echo "Started at: $(date)"
    echo ""
    
    # Create base directory
    mkdir -p "$BASE_PATH" || {
        print_error "Failed to create base directory: $BASE_PATH"
        exit 1
    }
    
    # Create all model directories
    print_header "Creating directories"
    directories=(
        "ControlNet"
        "ControlNetPreprocessor"
        "diffusers"
        "embeddings"
        "ESRGAN"
        "Lora"
        "Stable-diffusion"
        "VAE"
        "adetailer"
    )
    
    for dir in "${directories[@]}"; do
        if mkdir -p "${MODELS_PATH}/${dir}" 2>/dev/null; then
            print_success "Created: ${MODELS_PATH}/${dir}"
        else
            print_error "Failed to create: ${MODELS_PATH}/${dir}"
        fi
    done
    
    # Clone extensions
    print_header "Cloning Extensions"
    
    extensions=(
        "https://github.com/altoiddealer/--sd-webui-ar-plusplus.git"
        "https://github.com/eduardoabreu81/sd-webui-tagcomplete-neo.git"
        "https://github.com/abzaloff/aadetailer-neoforge.git"
        "https://github.com/eduardoabreu81/sd-civitai-browser-neo.git"
        "https://github.com/Haoming02/sd-forge-couple.git"
        "https://github.com/Haoming02/sd-forge-nvidia-vfx.git"
        "https://github.com/Panchovix/reForge-Sigmas_merge.git"
        "https://github.com/Dusky-dev/sd-forge_neo-infinite-image-browsing-xl.git"
        "https://github.com/hnmr293/sd-webui-cutoff.git"
        "https://github.com/hako-mikan/sd-webui-cd-tuner.git"
        "https://github.com/shirayu/sd-webui-enable-checker.git"
        "https://github.com/hirorohi03/sd-webui-forge-spectrum.git"
        "https://github.com/Haoming02/sd-forge-negpip.git"
        "https://github.com/Haoming02/sd-webui-resharpen.git"
        "https://github.com/Haoming02/sd-webui-tabs-extension.git"
        "https://github.com/light-and-ray/sd-webui-yandere-inpaint-masked-content.git"
        "https://github.com/Replactionap/Stable-Diffusion-Webui-Civitai-Helper-RED-UPDATE.git"
        "https://github.com/yamosin/seedvr2-webui-neo-extension.git"
        "https://github.com/SiliconeShojo/ScribeNEO.git"
    )
    
    for ext in "${extensions[@]}"; do
        clone_extension "$ext"
    done
    
    # Download models
    print_header "Downloading Models"
    
    # VAE
    echo -e "\n${BLUE}Downloading VAEs...${NC}"
    download_file "https://civitai.red/api/download/models/648388?fileId=824329" "${MODELS_PATH}/VAE" ""
    
    # Embeddings
    echo -e "\n${BLUE}Downloading Embeddings...${NC}"
    embeddings=(
        "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor"
        "https://civitai.com/api/download/models/2121199?type=Model&format=Other"
        "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor"
    )
    for emb in "${embeddings[@]}"; do
        download_file "$emb" "${MODELS_PATH}/embeddings" ""
    done
    
    # Upscalers
    echo -e "\n${BLUE}Downloading Upscalers...${NC}"
    upscalers=(
        "https://civitai.red/api/download/models/164821?fileId=2037845"
        "https://civitai.red/api/download/models/2674200?fileId=2560903"
        "https://civitai.red/api/download/models/729727?fileId=643878"
    )
    for up in "${upscalers[@]}"; do
        download_file "$up" "${MODELS_PATH}/ESRGAN" ""
    done
    
    # Adetailer
    echo -e "\n${BLUE}Downloading Adetailer models...${NC}"
    adetailer=(
        "https://civitai.com/api/download/models/176512"
        "https://civitai.com/api/download/models/2509406?type=Model&format=PickleTensor"
        "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor"
        "https://civitai.com/api/download/models/168820?type=Archive&format=Other"
        "https://civitai.com/api/download/models/1780243?type=Archive&format=Other"
        "https://civitai.com/api/download/models/235730?type=Archive&format=Other"
        "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt"
        "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt"
        "https://civitai.red/api/download/models/465360?fileId=384289"
        "https://civitai.red/api/download/models/582139?fileId=497510"
        "https://civitai.red/api/download/models/2038997?fileId=1935916"
        "https://civitai.red/api/download/models/2350456?fileId=2240838"
    )
    for ad in "${adetailer[@]}"; do
        download_file "$ad" "${MODELS_PATH}/adetailer" ""
    done
    
    # Checkpoint
    echo -e "\n${BLUE}Downloading Checkpoint...${NC}"
    download_file "https://civitai.red/api/download/models/2883731?fileId=2763986" "${MODELS_PATH}/Stable-diffusion" ""
    
    # LoRA
    echo -e "\n${BLUE}Downloading LoRAs...${NC}"
    loras=(
        "https://civitai.red/api/download/models/2579082?fileId=2466259"
        "https://civitai.red/api/download/models/2177579?fileId=2070697"
        "https://civitai.red/api/download/models/2154919?fileId=2048262"
        "https://civitai.red/api/download/models/1905807?fileId=1804867"
        "https://civitai.red/api/download/models/2979435?fileId=2866837"
    )
    for lora in "${loras[@]}"; do
        download_file "$lora" "${MODELS_PATH}/Lora" ""
    done
    
    # ControlNet
    echo -e "\n${BLUE}Downloading ControlNet models...${NC}"
    controlnet=(
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_depth_mid.safetensors"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/t2i-adapter_diffusers_xl_lineart.safetensors"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/thibaud_xl_openpose_256lora.safetensors"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_canny_mid.safetensors"
        "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors"
        "https://huggingface.co/destitech/controlnet-inpaint-dreamer-sdxl/resolve/main/v2/diffusion_pytorch_model.fp16.safetensors"
        "https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor"
        "https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors"
        "https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors"
        "https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors"
        "https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors"
        "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet.safetensors"
        "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet_10w.safetensors"
        "https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32"
    )
    for cn in "${controlnet[@]}"; do
        download_file "$cn" "${MODELS_PATH}/ControlNet" ""
    done
    
    # Summary
    print_header "Setup Complete!"
    echo "Finished at: $(date)"
    echo ""
    echo -e "${GREEN}Successfully downloaded: $SUCCESS_COUNT items${NC}"
    echo -e "${YELLOW}Skipped (already exists): $SKIPPED_COUNT items${NC}"
    echo -e "${RED}Failed: $FAILED_COUNT items${NC}"
    echo ""
    echo -e "${BLUE}Total time: $(($SECONDS / 60)) minutes and $(($SECONDS % 60)) seconds${NC}"
    
    if [ $FAILED_COUNT -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Warning: $FAILED_COUNT items failed to download.${NC}"
        echo -e "${YELLOW}You may want to retry the failed downloads manually.${NC}"
        exit 1
    else
        echo -e "${GREEN}All items downloaded successfully!${NC}"
        exit 0
    fi
}

# Run the main function
main "$@"
