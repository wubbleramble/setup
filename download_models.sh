#!/usr/bin/env bash
#
# download.sh
# ------------------------------------------------------------------
# Downloads extensions and models into a Stable Diffusion WebUI Forge
# install, meant to be run from a Jupyter terminal cell like:
#   !bash download.sh
# or, from a Jupyter shell cell:
#   bash download.sh
#
# WHAT THIS SCRIPT DOES (in plain terms):
#   1. Clones each extension repo into the extensions/ folder.
#      If a folder with that repo name already exists, it's skipped
#      (this is the "duplicate" check for extensions).
#   2. Downloads each model file into its correct subfolder
#      (Lora, Stable-diffusion, VAE, ControlNet, etc).
#      Before downloading, it checks if a file with the same name
#      already exists in that folder, and skips the download if so.
#   3. Shows a live progress bar for whichever file is downloading
#      right now (one at a time — Civitai does not like concurrent
#      downloads from the same source and can throttle/kill them).
#   4. NEVER stops the whole script because one link failed. Every
#      single download is wrapped so a failure is just recorded and
#      the script moves on to the next one. At the very end you get
#      a summary of what succeeded, what was skipped, and what failed.
#
# WHERE FILES GO:
#   This assumes your Forge WebUI is at:
#     /workspace/stable-diffusion-webui-forge
#   with model folders under .../models/<Category>/ and extensions
#   under .../extensions/. If your path is different, change BASE_DIR
#   below (it's the only path variable you should need to touch).
# ------------------------------------------------------------------

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

# download_file <url> <target_dir> [explicit_filename]
#
# NOTE ON APPROACH: earlier versions of this script tried to ask the
# server for the real filename with a lightweight HEAD-style request
# ("--spider") BEFORE downloading, so duplicates could be skipped
# without wasting bandwidth. In practice, Civitai's servers often only
# send the real filename (via the Content-Disposition header) on the
# actual GET request — sometimes only after a redirect to their CDN —
# so the HEAD-style pre-check came back empty and every Civitai
# download failed with "Could not determine filename".
#
# This version instead lets `wget` do the one thing it's actually
# built to do well: follow redirects, read the real
# Content-Disposition header, and name the file correctly — via
# wget's own --content-disposition flag. To still support duplicate
# detection without wasting a full re-download, non-huggingface links
# (i.e. anything where we can't just read the filename off the URL)
# are downloaded to a temporary holding folder first; only once we
# know the real filename do we check if it's already in the target
# folder, and either discard the duplicate or move the new file in.
#
# Downloads a single file with a live progress bar. Skips if a file
# of the same name already exists in target_dir. Never exits the
# script on failure — just records it.
TMP_DL_DIR="$(mktemp -d)"

download_file() {
  local url="$1"
  local target_dir="$2"
  local filename="${3:-}"

  local auth_header=()
  if [[ "$url" == *civitai.com* || "$url" == *civitai.red* ]] && [ -n "$CIVITAI_TOKEN" ]; then
    auth_header=(--header="Authorization: Bearer ${CIVITAI_TOKEN}")
  fi

  # Case 1: filename was given explicitly, or it's a direct link
  # (e.g. huggingface) where the URL's last path segment is already
  # the real filename. We can check for a duplicate immediately,
  # without downloading anything first.
  if [ -z "$filename" ] && [[ "$url" != *civitai.com* && "$url" != *civitai.red* ]]; then
    filename="$(basename "${url%%\?*}")"
  fi

  if [ -n "$filename" ]; then
    local target_path="${target_dir}/${filename}"
    if [ -f "$target_path" ]; then
      log "  [SKIP] Already exists: $filename"
      SKIPPED+=("model: $filename")
      return 0
    fi
    log "  [DOWNLOAD] $filename -> $target_dir"
    if wget --progress=bar:force:noscroll "${auth_header[@]}" \
        -O "$target_path" "$url" 2>&1 | tee -a "$LOG_FILE"; then
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
    return 0
  fi

  # Case 2: filename unknown ahead of time (Civitai links). Download
  # into a temp folder, letting wget name the file itself from the
  # real Content-Disposition header, THEN check for duplicates.
  ( cd "$TMP_DL_DIR" && rm -f -- *  # clear temp dir from any previous file
    wget --progress=bar:force:noscroll --content-disposition \
      "${auth_header[@]}" "$url" 2>&1 ) | tee -a "$LOG_FILE"

  local downloaded_file
  downloaded_file="$(find "$TMP_DL_DIR" -maxdepth 1 -type f -printf '%f\n' | head -1)"

  if [ -z "$downloaded_file" ]; then
    log "  [FAIL] Download produced no file: $url"
    FAILED+=("model: (unknown filename) (url: $url) — no file was produced")
    return 1
  fi

  local downloaded_size
  downloaded_size="$(stat -c%s "${TMP_DL_DIR}/${downloaded_file}")"

  if [ "$downloaded_size" -le 10240 ]; then
    log "  [FAIL] $downloaded_file downloaded but looks invalid (too small)"
    rm -f "${TMP_DL_DIR:?}/${downloaded_file}"
    FAILED+=("model: $downloaded_file (url: $url) — file too small, likely bad link/token")
    return 1
  fi

  local target_path="${target_dir}/${downloaded_file}"
  if [ -f "$target_path" ]; then
    log "  [SKIP] Already exists (discarding re-download): $downloaded_file"
    SKIPPED+=("model: $downloaded_file")
    rm -f "${TMP_DL_DIR:?}/${downloaded_file}"
    return 0
  fi

  mv "${TMP_DL_DIR}/${downloaded_file}" "$target_path"
  log "  [OK] $downloaded_file"
  SUCCEEDED+=("model: $downloaded_file")
  return 0
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

rm -rf "$TMP_DL_DIR"
