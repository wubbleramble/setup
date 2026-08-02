#!/usr/bin/env bash

set -uo pipefail
# NOTE: intentionally NOT using `set -e` here. `set -e` would kill the
# whole script the moment any single command (like one failed wget)
# returns a non-zero exit code, which is exactly what we don't want.

# ==================== CONFIG (edit if needed) ====================
BASE_DIR="/workspace/stable-diffusion-webui-forge"

EXT_DIR="${BASE_DIR}/extensions"
MODELS_DIR="${BASE_DIR}/models"

CONTROLNET_DIR="${MODELS_DIR}/ControlNet"
CONTROLNET_PREPROCESSOR_DIR="${MODELS_DIR}/ControlNetPreprocessor"
DIFFUSERS_DIR="${MODELS_DIR}/diffusers"
EMBEDDINGS_DIR="${MODELS_DIR}/embeddings"
ESRGAN_DIR="${MODELS_DIR}/ESRGAN"
LORA_DIR="${MODELS_DIR}/Lora"
CHECKPOINT_DIR="${MODELS_DIR}/Stable-diffusion"
VAE_DIR="${MODELS_DIR}/VAE"
ADETAILER_DIR="${MODELS_DIR}/adetailer"

# Civitai API token, if your links need auth to resolve (recommended:
# export CIVITAI_TOKEN as an environment variable before running this
# script, rather than hardcoding it here, so it's never committed to
# the GitHub repo by accident).
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"

LOG_FILE="./download_log_$(date +%Y%m%d_%H%M%S).txt"

# ==================== INTERNAL STATE ====================
declare -a SUCCEEDED=()
declare -a SKIPPED=()
declare -a FAILED=()

# ==================== HELPERS ====================

log() {
  # Prints to the terminal AND appends to a log file, so you have a
  # record after the script finishes.
  echo -e "$1" | tee -a "$LOG_FILE"
}

ensure_dirs() {
  log "\n== Creating target folders (if they don't already exist) =="
  mkdir -p "$EXT_DIR" "$CONTROLNET_DIR" "$CONTROLNET_PREPROCESSOR_DIR" \
    "$DIFFUSERS_DIR" "$EMBEDDINGS_DIR" "$ESRGAN_DIR" "$LORA_DIR" \
    "$CHECKPOINT_DIR" "$VAE_DIR" "$ADETAILER_DIR"
}

# clone_extension <git_url>
# Clones a repo into EXT_DIR. Skips if the folder already exists.
clone_extension() {
  local url="$1"
  local name
  name="$(basename "$url" .git)"
  local target="${EXT_DIR}/${name}"

  if [ -d "$target" ]; then
    log "  [SKIP] Extension already exists: $name"
    SKIPPED+=("extension: $name")
    return 0
  fi

  log "  [CLONE] $name"
  if git clone --depth=1 "$url" "$target" 2>&1 | tee -a "$LOG_FILE"; then
    log "  [OK] $name"
    SUCCEEDED+=("extension: $name")
  else
    log "  [FAIL] $name"
    FAILED+=("extension: $name (url: $url)")
    # Clean up a half-cloned folder so a retry later doesn't think
    # it's already done.
    rm -rf "$target"
  fi
}

# get_civitai_filename <download_url>
# Civitai download URLs don't contain a real filename, so we ask the
# server what filename it intends to send (via the Content-Disposition
# header) WITHOUT downloading the whole file. This lets us check for
# duplicates before spending time/bandwidth on a redownload.
get_civitai_filename() {
  local url="$1"
  local auth_header=()
  if [ -n "$CIVITAI_TOKEN" ]; then
    auth_header=(--header="Authorization: Bearer ${CIVITAI_TOKEN}")
  fi
  # -S dumps headers to stderr, --spider does a HEAD-style check
  # without saving a body.
  wget --spider -S "${auth_header[@]}" "$url" 2>&1 \
    | grep -i "filename=" \
    | sed -E 's/.*filename="?([^";]+)"?.*/\1/' \
    | tail -1
}

# download_file <url> <target_dir> [explicit_filename]
# Downloads a single file with a live progress bar. Skips if a file
# of the same name already exists in target_dir. Never exits the
# script on failure — just records it.
download_file() {
  local url="$1"
  local target_dir="$2"
  local filename="${3:-}"

  local auth_header=()
  if [[ "$url" == *civitai.com* || "$url" == *civitai.red* ]] && [ -n "$CIVITAI_TOKEN" ]; then
    auth_header=(--header="Authorization: Bearer ${CIVITAI_TOKEN}")
  fi

  # If no filename was given explicitly, figure it out.
  if [ -z "$filename" ]; then
    if [[ "$url" == *civitai.com* || "$url" == *civitai.red* ]]; then
      filename="$(get_civitai_filename "$url")"
    else
      # For direct links (e.g. huggingface), the URL's last path
      # segment is normally the real filename.
      filename="$(basename "${url%%\?*}")"
    fi
  fi

  if [ -z "$filename" ]; then
    log "  [FAIL] Could not determine filename for: $url"
    FAILED+=("model: (unknown filename) (url: $url)")
    return 1
  fi

  local target_path="${target_dir}/${filename}"

  if [ -f "$target_path" ]; then
    log "  [SKIP] Already exists: $filename"
    SKIPPED+=("model: $filename")
    return 0
  fi

  log "  [DOWNLOAD] $filename -> $target_dir"
  if wget --progress=bar:force:noscroll "${auth_header[@]}" \
      -O "$target_path" "$url" 2>&1 | tee -a "$LOG_FILE"; then
    # wget can "succeed" (exit 0) but still have written a tiny error
    # page instead of the real file (e.g. bad/expired link). A quick
    # sanity check: anything under 10KB is almost certainly not a
    # real model/image file.
    if [ -s "$target_path" ] && [ "$(stat -c%s "$target_path")" -gt 10240 ]; then
      log "  [OK] $filename"
      SUCCEEDED+=("model: $filename")
    else
      log "  [FAIL] $filename downloaded but looks invalid (too small) — removing"
      rm -f "$target_path"
      FAILED+=("model: $filename (url: $url) — file too small, likely bad link/token")
    fi
  else
    log "  [FAIL] $filename"
    rm -f "$target_path"
    FAILED+=("model: $filename (url: $url)")
  fi
}

# ==================== MAIN ====================

ensure_dirs

log "\n== Extensions =="
EXTENSIONS=(
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
for url in "${EXTENSIONS[@]}"; do
  clone_extension "$url"
done

log "\n== VAE =="
download_file "https://civitai.red/api/download/models/648388?fileId=824329" "$VAE_DIR"

log "\n== Embeddings =="
EMBEDDINGS=(
  "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor"
  "https://civitai.com/api/download/models/2121199?type=Model&format=Other"
  "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor"
)
for url in "${EMBEDDINGS[@]}"; do
  download_file "$url" "$EMBEDDINGS_DIR"
done

log "\n== Upscalers (ESRGAN) =="
UPSCALERS=(
  "https://civitai.red/api/download/models/164821?fileId=2037845"
  "https://civitai.red/api/download/models/2674200?fileId=2560903"
  "https://civitai.red/api/download/models/729727?fileId=643878"
)
for url in "${UPSCALERS[@]}"; do
  download_file "$url" "$ESRGAN_DIR"
done

log "\n== ADetailer =="
ADETAILER=(
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
for url in "${ADETAILER[@]}"; do
  download_file "$url" "$ADETAILER_DIR"
done

log "\n== Checkpoint =="
download_file "https://civitai.red/api/download/models/2883731?fileId=2763986" "$CHECKPOINT_DIR"

log "\n== LoRA =="
LORAS=(
  "https://civitai.red/api/download/models/2579082?fileId=2466259"
  "https://civitai.red/api/download/models/2177579?fileId=2070697"
  "https://civitai.red/api/download/models/2154919?fileId=2048262"
  "https://civitai.red/api/download/models/1905807?fileId=1804867"
  "https://civitai.red/api/download/models/2979435?fileId=2866837"
)
for url in "${LORAS[@]}"; do
  download_file "$url" "$LORA_DIR"
done

log "\n== ControlNet =="
CONTROLNET=(
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
for url in "${CONTROLNET[@]}"; do
  download_file "$url" "$CONTROLNET_DIR"
done

# ==================== SUMMARY ====================
log "\n\n================ SUMMARY ================"
log "Succeeded: ${#SUCCEEDED[@]}"
log "Skipped (already existed): ${#SKIPPED[@]}"
log "Failed: ${#FAILED[@]}"

if [ "${#FAILED[@]}" -gt 0 ]; then
  log "\n-- Failed items (fix these links or rerun the script) --"
  for item in "${FAILED[@]}"; do
    log "  - $item"
  done
fi

log "\nFull log saved to: $LOG_FILE"
