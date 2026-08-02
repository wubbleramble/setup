#!/bin/bash

# Stable Diffusion WebUI Model Download Script with proper Civitai handling
# Run this from Jupyter terminal

# Base paths
BASE_PATH="/workspace/stable-diffusion-webui-forge"
MODELS_PATH="${BASE_PATH}/models"
EXTENSIONS_PATH="${BASE_PATH}/extensions"

# API Keys
CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
FAILED_COUNT=0
SUCCESS_COUNT=0
SKIPPED_COUNT=0
TOTAL_ITEMS=0

# Temporary directory
TEMP_DIR="/tmp/sd_download_$$"
mkdir -p "$TEMP_DIR"

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

# Function to get model info from Civitai API
get_civitai_model_info() {
    local model_id="$1"
    local api_url="https://civitai.com/api/v1/models/${model_id}"
    local response_file="${TEMP_DIR}/model_${model_id}.json"
    
    # Check if we already have the response
    if [ -f "$response_file" ]; then
        cat "$response_file"
        return 0
    fi
    
    # Build curl command with auth if available
    local curl_cmd="curl -s"
    if [ -n "$CIVITAI_API_KEY" ]; then
        curl_cmd="$curl_cmd -H 'Authorization: Bearer $CIVITAI_API_KEY'"
    fi
    
    # Fetch model info
    eval "$curl_cmd '$api_url'" > "$response_file"
    
    if [ -s "$response_file" ]; then
        cat "$response_file"
        return 0
    else
        return 1
    fi
}

# Function to download Civitai model with proper naming
download_civitai_model() {
    local url="$1"
    local destination="$2"
    local model_id=""
    local version_id=""
    
    # Extract model ID and version ID from URL
    if [[ "$url" =~ models/([0-9]+) ]]; then
        model_id="${BASH_REMATCH[1]}"
    fi
    
    if [[ "$url" =~ fileId=([0-9]+) ]]; then
        version_id="${BASH_REMATCH[1]}"
    fi
    
    if [ -z "$model_id" ]; then
        print_error "Could not extract model ID from URL: $url"
        return 1
    fi
    
    ((TOTAL_ITEMS++))
    mkdir -p "$destination"
    
    # Get model info from API
    local model_info=$(get_civitai_model_info "$model_id")
    
    if [ -z "$model_info" ] || [ "$model_info" = "null" ]; then
        print_error "Failed to get model info for ID: $model_id"
        # Fallback: use model ID as filename
        local fallback_name="${model_id}.safetensors"
        local fallback_path="${destination}/${fallback_name}"
        
        print_info "Falling back to download with ID: $fallback_name"
        if wget -q --show-progress "$url" -O "$fallback_path" 2>/dev/null; then
            print_success "Downloaded: $fallback_name"
            return 0
        else
            print_error "Failed to download: $fallback_name"
            rm -f "$fallback_path"
            return 1
        fi
    fi
    
    # Parse model info
    local model_name=$(echo "$model_info" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//' | sed 's/"//g' | sed 's/[^a-zA-Z0-9_ -]//g')
    local model_type=$(echo "$model_info" | grep -o '"type":"[^"]*"' | head -1 | sed 's/"type":"//' | sed 's/"//g')
    
    # Get version info
    local versions=$(echo "$model_info" | grep -o '"versions":\[[^]]*\]')
    local version_name=""
    local file_format="safetensors"
    
    # Try to find the specific version
    if [ -n "$version_id" ]; then
        version_name=$(echo "$model_info" | grep -o "\"id\":${version_id}[^}]*\"name\":\"[^\"]*\"" | sed 's/.*"name":"\([^"]*\)".*/\1/' | sed 's/[^a-zA-Z0-9_ -]//g')
    fi
    
    # If version name not found, try to get the first version
    if [ -z "$version_name" ] && [ -n "$versions" ]; then
        version_name=$(echo "$versions" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//' | sed 's/"//g' | sed 's/[^a-zA-Z0-9_ -]//g')
    fi
    
    # Determine file format from URL
    if [[ "$url" == *"format=SafeTensor"* ]] || [[ "$url" == *".safetensors"* ]]; then
        file_format="safetensors"
    elif [[ "$url" == *"format=PickleTensor"* ]] || [[ "$url" == *".ckpt"* ]]; then
        file_format="ckpt"
    elif [[ "$url" == *"format=Other"* ]] || [[ "$url" == *".bin"* ]]; then
        file_format="bin"
    elif [[ "$url" == *"format=Archive"* ]] || [[ "$url" == *".zip"* ]]; then
        file_format="zip"
    elif [[ "$url" == *".pt"* ]]; then
        file_format="pt"
    elif [[ "$url" == *".pth"* ]]; then
        file_format="pth"
    fi
    
    # Build final filename
    local final_name=""
    if [ -n "$model_name" ] && [ -n "$version_name" ]; then
        final_name="${model_name}_${version_name}.${file_format}"
    elif [ -n "$model_name" ]; then
        final_name="${model_name}.${file_format}"
    else
        final_name="${model_id}.${file_format}"
    fi
    
    # Clean filename
    final_name=$(echo "$final_name" | sed 's/[^a-zA-Z0-9._-]/_/g')
    
    local filepath="${destination}/${final_name}"
    
    # Check if file already exists
    if [ -f "$filepath" ]; then
        print_skip "File already exists: $final_name"
        return 0
    fi
    
    print_info "Model: $model_name (ID: $model_id)"
    print_info "Version: $version_name"
    print_info "Format: $file_format"
    print_info "Downloading: $final_name"
    
    # Download the file
    local wget_opts="-q --show-progress --progress=bar:force:noscroll --timeout=60 --tries=3"
    
    if [ -n "$CIVITAI_API_KEY" ]; then
        wget_opts="$wget_opts --header='Authorization: Bearer $CIVITAI_API_KEY'"
    fi
    
    if eval "wget $wget_opts '$url' -O '$filepath' 2>/dev/null"; then
        if [ -f "$filepath" ] && [ -s "$filepath" ]; then
            print_success "Downloaded: $final_name"
            
            # Save metadata
            local metadata_file="${destination}/${final_name%.*}_metadata.json"
            echo "$model_info" > "$metadata_file"
            
            # Save model description
            local description=$(echo "$model_info" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//' | sed 's/"//g' | sed 's/\\n/\n/g')
            if [ -n "$description" ] && [ "$description" != "null" ]; then
                echo -e "$description" > "${destination}/${final_name%.*}_description.txt"
            fi
            
            # Try to download preview image
            local image_url=$(echo "$model_info" | grep -o '"image":"[^"]*"' | head -1 | sed 's/"image":"//' | sed 's/"//g' | sed 's/\\//g')
            if [ -n "$image_url" ] && [ "$image_url" != "null" ]; then
                print_info "Downloading preview image..."
                wget -q "$image_url" -O "${destination}/${final_name%.*}_preview.jpg" 2>/dev/null || print_info "No preview image available"
            fi
            
            # Save trigger words
            local triggers=$(echo "$model_info" | grep -o '"triggerWords":"[^"]*"' | head -1 | sed 's/"triggerWords":"//' | sed 's/"//g')
            if [ -n "$triggers" ] && [ "$triggers" != "null" ]; then
                echo -e "$triggers" | tr ',' '\n' > "${destination}/${final_name%.*}_triggers.txt"
            fi
            
            return 0
        else
            print_error "Downloaded file is empty or corrupt: $final_name"
            rm -f "$filepath"
            return 1
        fi
    else
        print_error "Failed to download: $final_name"
        rm -f "$filepath"
        return 1
    fi
}

# Function to download from Hugging Face
download_huggingface_model() {
    local url="$1"
    local destination="$2"
    
    ((TOTAL_ITEMS++))
    mkdir -p "$destination"
    
    local filename=$(basename "${url%%\?*}")
    if [ -z "$filename" ]; then
        filename=$(echo "$url" | md5sum | cut -d' ' -f1)
    fi
    
    local filepath="${destination}/${filename}"
    
    if [ -f "$filepath" ]; then
        print_skip "File already exists: $filename"
        return 0
    fi
    
    print_info "Downloading: $filename"
    
    local wget_opts="-q --show-progress --progress=bar:force:noscroll --timeout=60 --tries=3"
    if [ -n "$HUGGINGFACE_TOKEN" ]; then
        wget_opts="$wget_opts --header='Authorization: Bearer $HUGGINGFACE_TOKEN'"
    fi
    
    if eval "wget $wget_opts '$url' -O '$filepath' 2>/dev/null"; then
        if [ -f "$filepath" ] && [ -s "$filepath" ]; then
            print_success "Downloaded: $filename"
            return 0
        fi
    fi
    
    print_error "Failed to download: $filename"
    rm -f "$filepath"
    return 1
}

# Function to clone git repository
clone_extension() {
    local repo_url="$1"
    local repo_name=$(basename "$repo_url" .git)
    local target_path="${EXTENSIONS_PATH}/${repo_name}"
    
    ((TOTAL_ITEMS++))
    
    if [ -d "$target_path" ]; then
        print_skip "Extension already exists: $repo_name"
        (cd "$target_path" && git pull 2>/dev/null)
        return 0
    fi
    
    print_info "Cloning: $repo_name"
    if git clone "$repo_url" "$target_path" 2>/dev/null; then
        print_success "Cloned: $repo_name"
        return 0
    else
        print_error "Failed to clone: $repo_name"
        rm -rf "$target_path"
        return 1
    fi
}

# Main execution
main() {
    print_header "Stable Diffusion WebUI Setup"
    echo "Started at: $(date)"
    echo ""
    
    # Check for API keys
    if [ -z "$CIVITAI_API_KEY" ]; then
        print_info "CIVITAI_API_KEY not set. Some downloads may fail."
        print_info "Get your key at: https://civitai.com/user/account"
    else
        print_info "✓ Civitai API key set"
    fi
    
    if [ -z "$HUGGINGFACE_TOKEN" ]; then
        print_info "HUGGINGFACE_TOKEN not set. Some downloads may fail."
        print_info "Get your token at: https://huggingface.co/settings/tokens"
    else
        print_info "✓ Hugging Face token set"
    fi
    echo ""
    
    # Create directories
    print_header "Creating directories"
    for dir in ControlNet ControlNetPreprocessor diffusers embeddings ESRGAN Lora Stable-diffusion VAE adetailer; do
        mkdir -p "${MODELS_PATH}/${dir}" && print_success "Created: ${MODELS_PATH}/${dir}"
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
    download_civitai_model "https://civitai.red/api/download/models/648388?fileId=824329" "${MODELS_PATH}/VAE"
    
    # Embeddings
    echo -e "\n${BLUE}Downloading Embeddings...${NC}"
    for url in \
        "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor" \
        "https://civitai.com/api/download/models/2121199?type=Model&format=Other" \
        "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor"; do
        download_civitai_model "$url" "${MODELS_PATH}/embeddings"
    done
    
    # Upscalers
    echo -e "\n${BLUE}Downloading Upscalers...${NC}"
    for url in \
        "https://civitai.red/api/download/models/164821?fileId=2037845" \
        "https://civitai.red/api/download/models/2674200?fileId=2560903" \
        "https://civitai.red/api/download/models/729727?fileId=643878"; do
        download_civitai_model "$url" "${MODELS_PATH}/ESRGAN"
    done
    
    # Adetailer
    echo -e "\n${BLUE}Downloading Adetailer models...${NC}"
    for url in \
        "https://civitai.com/api/download/models/176512" \
        "https://civitai.com/api/download/models/2509406?type=Model&format=PickleTensor" \
        "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor" \
        "https://civitai.com/api/download/models/168820?type=Archive&format=Other" \
        "https://civitai.com/api/download/models/1780243?type=Archive&format=Other" \
        "https://civitai.com/api/download/models/235730?type=Archive&format=Other" \
        "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt" \
        "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt" \
        "https://civitai.red/api/download/models/465360?fileId=384289" \
        "https://civitai.red/api/download/models/582139?fileId=497510" \
        "https://civitai.red/api/download/models/2038997?fileId=1935916" \
        "https://civitai.red/api/download/models/2350456?fileId=2240838"; do
        if [[ "$url" == *"huggingface"* ]]; then
            download_huggingface_model "$url" "${MODELS_PATH}/adetailer"
        else
            download_civitai_model "$url" "${MODELS_PATH}/adetailer"
        fi
    done
    
    # Checkpoint
    echo -e "\n${BLUE}Downloading Checkpoint...${NC}"
    download_civitai_model "https://civitai.red/api/download/models/2883731?fileId=2763986" "${MODELS_PATH}/Stable-diffusion"
    
    # LoRA
    echo -e "\n${BLUE}Downloading LoRAs...${NC}"
    for url in \
        "https://civitai.red/api/download/models/2579082?fileId=2466259" \
        "https://civitai.red/api/download/models/2177579?fileId=2070697" \
        "https://civitai.red/api/download/models/2154919?fileId=2048262" \
        "https://civitai.red/api/download/models/1905807?fileId=1804867" \
        "https://civitai.red/api/download/models/2979435?fileId=2866837"; do
        download_civitai_model "$url" "${MODELS_PATH}/Lora"
    done
    
    # ControlNet
    echo -e "\n${BLUE}Downloading ControlNet models...${NC}"
    for url in \
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth" \
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_depth_mid.safetensors" \
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors" \
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/t2i-adapter_diffusers_xl_lineart.safetensors" \
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/thibaud_xl_openpose_256lora.safetensors" \
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_canny_mid.safetensors" \
        "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" \
        "https://huggingface.co/destitech/controlnet-inpaint-dreamer-sdxl/resolve/main/v2/diffusion_pytorch_model.fp16.safetensors" \
        "https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor" \
        "https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors" \
        "https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors" \
        "https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors" \
        "https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors" \
        "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet.safetensors" \
        "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet_10w.safetensors" \
        "https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32"; do
        if [[ "$url" == *"huggingface"* ]]; then
            download_huggingface_model "$url" "${MODELS_PATH}/ControlNet"
        else
            download_civitai_model "$url" "${MODELS_PATH}/ControlNet"
        fi
    done
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    # Summary
    print_header "Setup Complete!"
    echo "Finished at: $(date)"
    echo ""
    echo -e "${GREEN}Successfully downloaded: $SUCCESS_COUNT items${NC}"
    echo -e "${YELLOW}Skipped (already exists): $SKIPPED_COUNT items${NC}"
    echo -e "${RED}Failed: $FAILED_COUNT items${NC}"
    echo -e "${BLUE}Total items processed: $TOTAL_ITEMS${NC}"
    echo ""
    echo -e "${BLUE}Total time: $(($SECONDS / 60)) minutes and $(($SECONDS % 60)) seconds${NC}"
    
    if [ $FAILED_COUNT -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Warning: $FAILED_COUNT items failed to download.${NC}"
        echo -e "${YELLOW}Make sure your API keys are set correctly:${NC}"
        echo -e "${YELLOW}  export CIVITAI_API_KEY='your_key'${NC}"
        echo -e "${YELLOW}  export HUGGINGFACE_TOKEN='your_token'${NC}"
        exit 1
    else
        echo -e "${GREEN}All items downloaded successfully!${NC}"
        exit 0
    fi
}

main "$@"
