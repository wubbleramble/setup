#!/bin/bash

# Stable Diffusion WebUI Model Download Script with proper filename handling
# Run this from Jupyter terminal

# Base paths
BASE_PATH="/workspace/stable-diffusion-webui-forge"
MODELS_PATH="${BASE_PATH}/models"
EXTENSIONS_PATH="${BASE_PATH}/extensions"

# API Keys (set these before running)
CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"

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
TOTAL_ITEMS=0

# Temporary directory for API responses
TEMP_DIR="/tmp/sd_download_$$"
mkdir -p "$TEMP_DIR"

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

# Function to get proper filename from Civitai response
get_civitai_filename() {
    local url="$1"
    local temp_response="${TEMP_DIR}/civitai_response_$$.json"
    
    # Try to get filename from headers first
    local filename=""
    
    # Method 1: Try to get filename from Content-Disposition
    if command -v curl >/dev/null 2>&1; then
        # Use curl to get headers
        local headers=$(curl -sI -L "$url" 2>/dev/null)
        if [[ "$headers" =~ filename=\"([^\"]+)\" ]]; then
            filename="${BASH_REMATCH[1]}"
            echo "$filename"
            return 0
        elif [[ "$headers" =~ filename=([^;\ ]+) ]]; then
            filename="${BASH_REMATCH[1]}"
            echo "$filename"
            return 0
        fi
    fi
    
    # Method 2: Try to get model info from API
    if [[ "$url" == *"civitai.com/api/download/models/"* ]]; then
        local model_id=$(echo "$url" | sed -n 's/.*models\/\([0-9]*\).*/\1/p')
        local api_url="https://civitai.com/api/v1/models/${model_id}"
        
        if command -v curl >/dev/null 2>&1; then
            local api_response=$(curl -s "$api_url" 2>/dev/null)
            if [ -n "$api_response" ]; then
                # Try to get model name
                local model_name=$(echo "$api_response" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//' | sed 's/"//')
                if [ -n "$model_name" ] && [ "$model_name" != "null" ]; then
                    # Get version info
                    local version_name=$(echo "$api_response" | grep -o '"name":"[^"]*"' | tail -1 | sed 's/"name":"//' | sed 's/"//')
                    if [ -n "$version_name" ] && [ "$version_name" != "null" ]; then
                        echo "${model_name}_${version_name}"
                        return 0
                    else
                        echo "${model_name}"
                        return 0
                    fi
                fi
            fi
        fi
    fi
    
    # Method 3: Fallback - use URL parameters
    if [[ "$url" == *"format="* ]]; then
        local format=$(echo "$url" | grep -o "format=[^&]*" | cut -d= -f2)
        if [[ "$format" == "SafeTensor" ]]; then
            echo "model.safetensors"
            return 0
        elif [[ "$format" == "PickleTensor" ]]; then
            echo "model.ckpt"
            return 0
        elif [[ "$format" == "Other" ]]; then
            echo "model.bin"
            return 0
        elif [[ "$format" == "Archive" ]]; then
            echo "model.zip"
            return 0
        fi
    fi
    
    # Method 4: Use the last part of URL
    local basename=$(basename "${url%%\?*}")
    if [ -n "$basename" ] && [ "$basename" != "download" ]; then
        echo "$basename"
        return 0
    fi
    
    # Last resort: use model ID with .safetensors
    if [[ "$url" == *"civitai.com/api/download/models/"* ]]; then
        local id=$(echo "$url" | sed -n 's/.*models\/\([0-9]*\).*/\1/p')
        if [ -n "$id" ]; then
            # Check if file format is specified in URL
            if [[ "$url" == *"format=SafeTensor"* ]]; then
                echo "${id}.safetensors"
                return 0
            elif [[ "$url" == *"format=PickleTensor"* ]]; then
                echo "${id}.ckpt"
                return 0
            elif [[ "$url" == *"format=Other"* ]]; then
                echo "${id}.bin"
                return 0
            elif [[ "$url" == *"format=Archive"* ]]; then
                echo "${id}.zip"
                return 0
            else
                echo "${id}.safetensors"
                return 0
            fi
        fi
    fi
    
    # Default fallback
    echo "download_$(date +%s).file"
    return 0
}

# Function to download and save model metadata
save_model_metadata() {
    local url="$1"
    local destination="$2"
    local filename="$3"
    
    # Only for Civitai models
    if [[ "$url" != *"civitai.com"* ]]; then
        return 0
    fi
    
    # Extract model ID
    local model_id=$(echo "$url" | sed -n 's/.*models\/\([0-9]*\).*/\1/p')
    if [ -z "$model_id" ]; then
        return 0
    fi
    
    # Get model info from API
    local api_url="https://civitai.com/api/v1/models/${model_id}"
    local metadata_file="${destination}/${filename%.*}_metadata.json"
    
    print_info "Fetching metadata for model ID: $model_id"
    
    if command -v curl >/dev/null 2>&1; then
        local api_response=$(curl -s "$api_url" 2>/dev/null)
        if [ -n "$api_response" ] && [ "$api_response" != "null" ]; then
            # Save metadata
            echo "$api_response" > "$metadata_file"
            
            # Try to download preview image
            local image_url=$(echo "$api_response" | grep -o '"image":"[^"]*"' | head -1 | sed 's/"image":"//' | sed 's/"//' | sed 's/\\//g')
            if [ -n "$image_url" ] && [ "$image_url" != "null" ]; then
                local image_file="${destination}/${filename%.*}_preview.jpg"
                print_info "Downloading preview image..."
                if command -v wget >/dev/null 2>&1; then
                    wget -q "$image_url" -O "$image_file" 2>/dev/null || print_error "Failed to download preview image"
                elif command -v curl >/dev/null 2>&1; then
                    curl -s "$image_url" -o "$image_file" 2>/dev/null || print_error "Failed to download preview image"
                fi
            fi
            
            # Extract and save trigger words/activation tags
            local trigger_words=$(echo "$api_response" | grep -o '"triggerWords":"[^"]*"' | head -1 | sed 's/"triggerWords":"//' | sed 's/"//' | sed 's/\\//g')
            if [ -n "$trigger_words" ] && [ "$trigger_words" != "null" ]; then
                local trigger_file="${destination}/${filename%.*}_triggers.txt"
                echo -e "$trigger_words" | tr ',' '\n' > "$trigger_file"
                print_info "Saved trigger words: $trigger_words"
            fi
            
            # Save model description
            local description=$(echo "$api_response" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//' | sed 's/"//' | sed 's/\\n/\n/g' | sed 's/\\r/\r/g')
            if [ -n "$description" ] && [ "$description" != "null" ]; then
                local desc_file="${destination}/${filename%.*}_description.txt"
                echo -e "$description" > "$desc_file"
            fi
            
            print_success "Saved metadata for $filename"
            return 0
        fi
    fi
    
    return 1
}

# Function to download file with proper error handling
download_file() {
    local url="$1"
    local destination="$2"
    local filename="$3"
    local is_civitai="$4"
    local is_huggingface="$5"
    
    ((TOTAL_ITEMS++))
    
    # Create destination directory if it doesn't exist
    mkdir -p "$destination" || {
        print_error "Failed to create directory: $destination"
        return 1
    }
    
    # Get proper filename
    if [ -z "$filename" ]; then
        if [ "$is_civitai" = "true" ]; then
            filename=$(get_civitai_filename "$url")
        else
            # For huggingface and others
            filename=$(basename "${url%%\?*}")
            if [ -z "$filename" ] || [ "$filename" = "download" ] || [ "$filename" = "download" ]; then
                filename=$(echo "$url" | md5sum | cut -d' ' -f1)
                # Add extension based on URL
                if [[ "$url" == *"format=SafeTensor"* ]] || [[ "$url" == *".safetensors"* ]]; then
                    filename="${filename}.safetensors"
                elif [[ "$url" == *"format=PickleTensor"* ]] || [[ "$url" == *".ckpt"* ]]; then
                    filename="${filename}.ckpt"
                elif [[ "$url" == *".pt"* ]]; then
                    filename="${filename}.pt"
                elif [[ "$url" == *".pth"* ]]; then
                    filename="${filename}.pth"
                elif [[ "$url" == *".bin"* ]]; then
                    filename="${filename}.bin"
                elif [[ "$url" == *".zip"* ]]; then
                    filename="${filename}.zip"
                else
                    filename="${filename}.safetensors"
                fi
            fi
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
    
    # Prepare wget options
    local wget_opts="-q --show-progress --progress=bar:force:noscroll --content-disposition --timeout=60 --tries=2 --retry-connrefused"
    
    # Add authentication headers
    if [ "$is_civitai" = "true" ] && [ -n "$CIVITAI_API_KEY" ]; then
        wget_opts="$wget_opts --header='Authorization: Bearer $CIVITAI_API_KEY'"
        print_info "Using Civitai API key"
    fi
    
    if [ "$is_huggingface" = "true" ] && [ -n "$HUGGINGFACE_TOKEN" ]; then
        wget_opts="$wget_opts --header='Authorization: Bearer $HUGGINGFACE_TOKEN'"
        print_info "Using Hugging Face token"
    fi
    
    # Download with wget - properly handle errors
    if eval "wget $wget_opts '$url' -O '$filepath' 2>/dev/null"; then
        # Verify file exists and has content
        if [ -f "$filepath" ] && [ -s "$filepath" ]; then
            print_success "Downloaded: $filename"
            
            # Save metadata for Civitai models
            if [ "$is_civitai" = "true" ]; then
                save_model_metadata "$url" "$destination" "$filename"
            fi
            
            return 0
        else
            print_error "Downloaded file is empty or corrupt: $filename"
            rm -f "$filepath" 2>/dev/null
            return 1
        fi
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
    
    ((TOTAL_ITEMS++))
    
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
    
    # Check for API keys
    if [ -z "$CIVITAI_API_KEY" ]; then
        print_info "CIVITAI_API_KEY not set. Civitai downloads may fail for protected models."
        print_info "To set: export CIVITAI_API_KEY='your_key_here'"
    fi
    
    if [ -z "$HUGGINGFACE_TOKEN" ]; then
        print_info "HUGGINGFACE_TOKEN not set. Hugging Face downloads may fail for gated models."
        print_info "To set: export HUGGINGFACE_TOKEN='your_token_here'"
    fi
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
    
    # VAE (Civitai)
    echo -e "\n${BLUE}Downloading VAEs...${NC}"
    download_file "https://civitai.red/api/download/models/648388?fileId=824329" "${MODELS_PATH}/VAE" "" "true" "false"
    
    # Embeddings (Civitai)
    echo -e "\n${BLUE}Downloading Embeddings...${NC}"
    embeddings=(
        "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor"
        "https://civitai.com/api/download/models/2121199?type=Model&format=Other"
        "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor"
    )
    for emb in "${embeddings[@]}"; do
        download_file "$emb" "${MODELS_PATH}/embeddings" "" "true" "false"
    done
    
    # Upscalers (Civitai)
    echo -e "\n${BLUE}Downloading Upscalers...${NC}"
    upscalers=(
        "https://civitai.red/api/download/models/164821?fileId=2037845"
        "https://civitai.red/api/download/models/2674200?fileId=2560903"
        "https://civitai.red/api/download/models/729727?fileId=643878"
    )
    for up in "${upscalers[@]}"; do
        download_file "$up" "${MODELS_PATH}/ESRGAN" "" "true" "false"
    done
    
    # Adetailer (Mix of Civitai and Hugging Face)
    echo -e "\n${BLUE}Downloading Adetailer models...${NC}"
    adetailer=(
        "https://civitai.com/api/download/models/176512|false|false"
        "https://civitai.com/api/download/models/2509406?type=Model&format=PickleTensor|true|false"
        "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor|true|false"
        "https://civitai.com/api/download/models/168820?type=Archive&format=Other|true|false"
        "https://civitai.com/api/download/models/1780243?type=Archive&format=Other|true|false"
        "https://civitai.com/api/download/models/235730?type=Archive&format=Other|true|false"
        "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt|false|false"
        "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt|false|false"
        "https://civitai.red/api/download/models/465360?fileId=384289|true|false"
        "https://civitai.red/api/download/models/582139?fileId=497510|true|false"
        "https://civitai.red/api/download/models/2038997?fileId=1935916|true|false"
        "https://civitai.red/api/download/models/2350456?fileId=2240838|true|false"
    )
    for entry in "${adetailer[@]}"; do
        IFS='|' read -r url is_civitai is_hf <<< "$entry"
        if [[ "$url" == *"civitai"* ]] || [ "$is_civitai" = "true" ]; then
            download_file "$url" "${MODELS_PATH}/adetailer" "" "true" "false"
        elif [[ "$url" == *"huggingface"* ]] || [ "$is_hf" = "true" ]; then
            download_file "$url" "${MODELS_PATH}/adetailer" "" "false" "true"
        else
            download_file "$url" "${MODELS_PATH}/adetailer" "" "false" "false"
        fi
    done
    
    # Checkpoint (Civitai)
    echo -e "\n${BLUE}Downloading Checkpoint...${NC}"
    download_file "https://civitai.red/api/download/models/2883731?fileId=2763986" "${MODELS_PATH}/Stable-diffusion" "" "true" "false"
    
    # LoRA (Civitai)
    echo -e "\n${BLUE}Downloading LoRAs...${NC}"
    loras=(
        "https://civitai.red/api/download/models/2579082?fileId=2466259"
        "https://civitai.red/api/download/models/2177579?fileId=2070697"
        "https://civitai.red/api/download/models/2154919?fileId=2048262"
        "https://civitai.red/api/download/models/1905807?fileId=1804867"
        "https://civitai.red/api/download/models/2979435?fileId=2866837"
    )
    for lora in "${loras[@]}"; do
        download_file "$lora" "${MODELS_PATH}/Lora" "" "true" "false"
    done
    
    # ControlNet (Mix of Hugging Face and Civitai)
    echo -e "\n${BLUE}Downloading ControlNet models...${NC}"
    controlnet=(
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth|false|false"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_depth_mid.safetensors|false|false"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors|false|false"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/t2i-adapter_diffusers_xl_lineart.safetensors|false|false"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/thibaud_xl_openpose_256lora.safetensors|false|false"
        "https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/diffusers_xl_canny_mid.safetensors|false|false"
        "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors|false|false"
        "https://huggingface.co/destitech/controlnet-inpaint-dreamer-sdxl/resolve/main/v2/diffusion_pytorch_model.fp16.safetensors|false|false"
        "https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor|true|false"
        "https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors|false|false"
        "https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors|false|false"
        "https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors|false|false"
        "https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors|false|false"
        "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet.safetensors|false|false"
        "https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet_10w.safetensors|false|false"
        "https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32|true|false"
    )
    for entry in "${controlnet[@]}"; do
        IFS='|' read -r url is_civitai is_hf <<< "$entry"
        if [[ "$url" == *"civitai"* ]] || [ "$is_civitai" = "true" ]; then
            download_file "$url" "${MODELS_PATH}/ControlNet" "" "true" "false"
        elif [[ "$url" == *"huggingface"* ]] || [ "$is_hf" = "true" ]; then
            download_file "$url" "${MODELS_PATH}/ControlNet" "" "false" "true"
        else
            download_file "$url" "${MODELS_PATH}/ControlNet" "" "false" "false"
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
        echo -e "${YELLOW}Possible reasons:${NC}"
        echo -e "${YELLOW}  - Missing API keys (set CIVITAI_API_KEY and/or HUGGINGFACE_TOKEN)${NC}"
        echo -e "${YELLOW}  - Network connectivity issues${NC}"
        echo -e "${YELLOW}  - Rate limiting (wait and retry)${NC}"
        echo ""
        echo -e "${YELLOW}To retry failed downloads:${NC}"
        echo -e "${YELLOW}  export CIVITAI_API_KEY='your_key'${NC}"
        echo -e "${YELLOW}  export HUGGINGFACE_TOKEN='your_token'${NC}"
        echo -e "${YELLOW}  ./download_models.sh${NC}"
        exit 1
    else
        echo -e "${GREEN}All items downloaded successfully!${NC}"
        exit 0
    fi
}

# Run the main function
main "$@"
