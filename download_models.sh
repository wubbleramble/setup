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
#   5. If a downloaded file is a .zip, it's automatically extracted
#      into the SAME folder the zip was downloaded into (the archive
#      itself is left in place afterward — it is not deleted).
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
TEXT_ENCODER_DIR="${MODELS_DIR}/text_encoder"
ADETAILER_DIR="${MODELS_DIR}/adetailer"

# Civitai API key, if your links need auth to resolve. This script
# reads it from the environment — set it BEFORE running the script,
# e.g. in your terminal session:
#   export CIVITAI_API_KEY="your_key_here"
# It is never written into this file, so it's safe for this script
# to live in a public GitHub repo.
CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"

# Optional: Hugging Face token, for gated/private model repos. Public
# huggingface.co downloads (like the ControlNet/adetailer links below)
# don't need this, but it's picked up automatically if set.
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"

LOG_FILE="./download_log_$(date +%Y%m%d_%H%M%S).txt"

# ==================== INTERRUPT HANDLING ====================
#
# Without this trap, pressing Ctrl+C (in a Jupyter terminal or
# anywhere else) while a wget is running gets swallowed by the retry
# loop below -- it just looks like "that attempt failed", so the
# script retries the SAME file up to 5 times and then quietly moves
# on to the NEXT one, instead of actually stopping. This trap makes
# an interrupt signal (Ctrl+C / SIGINT, or SIGTERM) immediately clean
# up temp folders and exit the whole script, no matter what it was
# doing at the time.
cleanup_and_exit_on_interrupt() {
  echo -e "\n[INTERRUPTED] Caught interrupt signal — stopping now." | tee -a "$LOG_FILE" 2>/dev/null
  rm -rf "${TMP_DL_DIR:-}" "${META_TMP_DIR:-}" 2>/dev/null
  exit 130
}
trap cleanup_and_exit_on_interrupt INT TERM

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
    "$CHECKPOINT_DIR" "$VAE_DIR" "$ADETAILER_DIR" "$TEXT_ENCODER_DIR"
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

# -------------------- Archive extraction support --------------------
#
# maybe_extract_archive <file_path> <target_dir>
#
# If the downloaded file is a .zip, extract it in place (into the
# same folder the zip lives in). The zip itself is left on disk
# afterward — only extracted, not deleted — in case anything inside
# needs re-extracting later or the archive is the thing you actually
# wanted to keep. Safe to call on non-zip files; it just does nothing.
maybe_extract_archive() {
  local file_path="$1"
  local target_dir="$2"
  local base_name
  base_name="$(basename "$file_path")"

  case "$file_path" in
    *.zip|*.ZIP)
      if ! command -v unzip >/dev/null 2>&1; then
        log "  [WARN] 'unzip' is not installed — skipping extraction of $base_name"
        return 1
      fi
      log "  [EXTRACT] Unzipping $base_name into $target_dir"
      if unzip -o -q "$file_path" -d "$target_dir" 2>>"$LOG_FILE"; then
        log "  [OK] Extracted $base_name"
      else
        log "  [WARN] Extraction failed for $base_name (archive may be corrupt or password-protected)"
        return 1
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

# -------------------- Civitai metadata support --------------------
#
# For Civitai links, we now call Civitai's real metadata API
# (api/v1/model-versions/{id}) BEFORE downloading. This gets us:
#   - the real filename (more reliable than guessing from headers)
#   - the exact expected file size, so we can confirm a huge download
#     actually completed instead of silently ending up truncated
#   - trigger words / trained activation words (for LoRAs especially)
#   - a thumbnail preview image URL
#
# This requires python3 (for parsing the JSON) and curl, both of
# which are already present on essentially every Jupyter/vast.ai
# image. If either is missing, the script automatically falls back
# to the older "download first, read filename from headers" method.
HAVE_PY3="$(command -v python3 || true)"
HAVE_CURL="$(command -v curl || true)"

META_TMP_DIR="$(mktemp -d)"

# civitai_fetch_metadata <url> <out_prefix>
# On success, writes three files under $META_TMP_DIR named
# <out_prefix>.filename / .size_bytes / .thumb_url, and leaves the
# full raw API JSON at <out_prefix>.json (used later for the sidecar
# metadata file with trigger words). Returns 1 if anything about this
# lookup didn't work (missing tools, no ID found, API error, etc.) —
# callers should treat that as "fall back to the old method", not a
# fatal error.
civitai_fetch_metadata() {
  local url="$1"
  local prefix="$2"

  [ -n "$HAVE_PY3" ] && [ -n "$HAVE_CURL" ] || return 1

  local mv_id
  mv_id="$(echo "$url" | grep -oE '/models/[0-9]+' | head -1 | grep -oE '[0-9]+')"
  [ -n "$mv_id" ] || return 1

  local file_id
  file_id="$(echo "$url" | grep -oE 'fileId=[0-9]+' | grep -oE '[0-9]+')"

  local auth=()
  [ -n "$CIVITAI_API_KEY" ] && auth=(-H "Authorization: Bearer ${CIVITAI_API_KEY}")

  local raw_json="${META_TMP_DIR}/${prefix}.json"
  # Always query the official civitai.com API for metadata, even if
  # the download link itself points at the civitai.red mirror.
  if ! curl -fsSL "${auth[@]}" "https://civitai.com/api/v1/model-versions/${mv_id}" \
      -o "$raw_json" 2>>"$LOG_FILE"; then
    return 1
  fi
  [ -s "$raw_json" ] || return 1

  local parsed
  parsed="$(FILE_ID="$file_id" python3 <<PYEOF
import json, os
try:
    with open("$raw_json") as fh:
        data = json.load(fh)
    file_id = os.environ.get("FILE_ID") or ""
    files = data.get("files", []) or []
    chosen = None
    if file_id:
        for f in files:
            if str(f.get("id")) == file_id:
                chosen = f
                break
    if chosen is None:
        for f in files:
            if f.get("primary"):
                chosen = f
                break
    if chosen is None and files:
        chosen = files[0]
    name = chosen.get("name", "") if chosen else ""
    size_kb = chosen.get("sizeKB", 0) if chosen else 0
    size_bytes = int(size_kb * 1024) if size_kb else 0
    images = data.get("images", []) or []
    thumb = images[0].get("url", "") if images else ""
    print(name)
    print(size_bytes)
    print(thumb)
except Exception:
    print("")
    print("0")
    print("")
PYEOF
)"

  local pfilename psize pthumb
  { IFS= read -r pfilename; IFS= read -r psize; IFS= read -r pthumb; } <<< "$parsed"

  [ -n "$pfilename" ] || return 1

  echo -n "$pfilename" > "${META_TMP_DIR}/${prefix}.filename"
  echo -n "$psize" > "${META_TMP_DIR}/${prefix}.size_bytes"
  echo -n "$pthumb" > "${META_TMP_DIR}/${prefix}.thumb_url"
  return 0
}

# save_civitai_sidecar <raw_json_path> <thumb_url> <target_dir> <filename>
# Writes a {filename}.json with model name / base model / trigger
# words, and a best-effort thumbnail. Called for every successful
# Civitai download that had working metadata — trigger words matter
# most for LoRAs, but thumbnails are useful across all categories.
# Failures here are logged but never fail the download itself.
#
# THUMBNAIL NAMING FIX: the preview image is now saved as
# "<name-without-original-extension>.preview.png" (e.g.
# "mymodel.preview.png" for "mymodel.safetensors") instead of the
# old "<full-filename>.preview.png" (e.g. "mymodel.safetensors.preview.png").
# Forge/A1111-style extensions like Civitai Helper and the Civitai
# Browser extension only recognize the first form — that mismatch is
# why thumbnails weren't showing up in the UI even though the image
# files were being downloaded successfully.
save_civitai_sidecar() {
  local raw_json="$1"
  local thumb_url="$2"
  local target_dir="$3"
  local filename="$4"
  local base_name="${filename%.*}"

  if [ -n "$HAVE_PY3" ] && [ -s "$raw_json" ]; then
    OUT_PATH="${target_dir}/${filename}.json" python3 <<PYEOF || log "  [WARN] Could not write metadata sidecar for $filename"
import json, os
with open("$raw_json") as fh:
    data = json.load(fh)
sidecar = {
    "model_name": (data.get("model") or {}).get("name", ""),
    "version_name": data.get("name", ""),
    "base_model": data.get("baseModel", ""),
    "trained_words": data.get("trainedWords", []) or [],
}
with open(os.environ["OUT_PATH"], "w") as out:
    json.dump(sidecar, out, indent=2)
PYEOF
    log "  [META] Saved trigger words / info to ${filename}.json"
  fi

  if [ -n "$thumb_url" ]; then
    if wget -q -O "${target_dir}/${base_name}.preview.png" "$thumb_url"; then
      log "  [META] Saved thumbnail to ${base_name}.preview.png"
    else
      log "  [WARN] Thumbnail download failed for $filename"
      rm -f "${target_dir}/${base_name}.preview.png"
    fi
  fi
}

# -------------------- Resumable download core --------------------
#
# download_with_retry <url> <output_path> <auth_header...>
#
# IMPORTANT DETAIL ABOUT CIVITAI: civitai.red / civitai.com redirect
# to a temporary, cryptographically-signed Cloudflare R2 URL that's
# generated fresh on every request (visible in the log as the long
# X-Amz-Signature... URL). If a partial file already exists locally
# and wget tries to resume (sends a Range header) against a BRAND
# NEW signed URL from a fresh request, R2 rejects it with a plain
# "400 Bad Request" rather than honoring the resume.
#
# So: resume (-c) is still used, but only within a single wget
# invocation's own internal retries (--tries=3) — those reconnect to
# the SAME already-resolved signed URL, which is safe. At the OUTER
# level (a brand new attempt after several internal retries failed),
# any partial file is deleted first, so the next attempt starts a
# clean download against whatever fresh redirect it gets. This trades
# a bit of bandwidth on repeated failures for actually working.
MAX_ATTEMPTS=5

download_with_retry() {
  local url="$1"
  local output_path="$2"
  local resume_safe="$3"
  shift 3
  local auth_header=("$@")

  local attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ "$attempt" -gt 1 ]; then
      if [ "$resume_safe" = "1" ]; then
        log "  [RETRY] Attempt ${attempt}/${MAX_ATTEMPTS} (resuming from $(du -h "$output_path" 2>/dev/null | cut -f1 || echo 0))"
      else
        log "  [RETRY] Attempt ${attempt}/${MAX_ATTEMPTS} (starting fresh — previous signed URL is no longer valid to resume against)"
        rm -f "$output_path"
      fi
      sleep 5
    fi
    wget -c --tries=3 --timeout=60 --waitretry=10 \
        --progress=bar:force:noscroll "${auth_header[@]}" \
        -O "$output_path" "$url" 2>&1 | tee -a "$LOG_FILE"
    local wget_status="${PIPESTATUS[0]}"
    if [ "$wget_status" -eq 0 ]; then
      return 0
    fi
    # 130 = killed by SIGINT (Ctrl+C), 143 = killed by SIGTERM. Either
    # way, this was a deliberate stop, not a network hiccup -- don't
    # treat it as "attempt failed, try again", let it propagate up so
    # the whole script actually stops instead of retrying/continuing.
    if [ "$wget_status" -eq 130 ] || [ "$wget_status" -eq 143 ]; then
      cleanup_and_exit_on_interrupt
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# download_with_retry_curl <url> <output_path> <auth_header...>
#
# Used ONLY for Civitai links. Both previous approaches for Civitai
# turned out broken in different ways:
#   - Handing wget the original civitai.red URL with the Authorization
#     header attached: wget follows the 307 redirect itself but keeps
#     forwarding that SAME header to the final Cloudflare R2 URL. R2's
#     own signed query-string is already self-authenticating, so the
#     extra header is a conflicting-auth combo R2 always rejects with
#     "400 Bad Request".
#   - Manually pre-resolving the redirect and stripping the header
#     before ever contacting R2: works for public files, but a file
#     that genuinely needs the API key to see the redirect AT ALL
#     (early-access/gated content) then fails with a plain
#     "401 Unauthorized" straight from civitai.red, since the header
#     never gets sent anywhere.
#
# curl actually solves both at once: with -L (follow redirects), curl
# has a built-in security feature where it automatically drops the
# Authorization header when a redirect crosses to a DIFFERENT host.
# So the Civitai API key is sent to civitai.red (satisfying gated
# files) but is never forwarded to the R2 domain (avoiding the
# conflicting-auth 400). This is the correct, general fix — no manual
# redirect resolution needed at all.
download_with_retry_curl() {
  local url="$1"
  local output_path="$2"
  shift 2
  local auth_header=("$@")

  local attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ "$attempt" -gt 1 ]; then
      log "  [RETRY] Attempt ${attempt}/${MAX_ATTEMPTS} (resuming from $(du -h "$output_path" 2>/dev/null | cut -f1 || echo 0))"
      sleep 5
    fi
    curl -fL --retry 2 --retry-delay 5 --connect-timeout 30 \
        -C - --progress-bar "${auth_header[@]}" \
        -o "$output_path" "$url" 2>&1 | tee -a "$LOG_FILE"
    local curl_status="${PIPESTATUS[0]}"
    if [ "$curl_status" -eq 0 ]; then
      return 0
    fi
    # 130 = killed by SIGINT (Ctrl+C), 143 = killed by SIGTERM -- a
    # deliberate stop, not a network hiccup. Let it propagate up so
    # the whole script actually stops instead of retrying/continuing.
    if [ "$curl_status" -eq 130 ] || [ "$curl_status" -eq 143 ]; then
      cleanup_and_exit_on_interrupt
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# download_file <url> <target_dir> [explicit_filename]
#
# Downloads a single file with a live progress bar. Skips if a file
# of the same name already exists in target_dir. Never exits the
# script on failure — just records it. For Civitai links, also
# fetches and saves trigger words + thumbnail (for Checkpoints/LoRAs).
# If the downloaded file turns out to be a .zip, it's extracted into
# the same target_dir right after the download finishes.
download_file() {
  local url="$1"
  local target_dir="$2"
  local filename="${3:-}"
  local is_civitai=0
  [[ "$url" == *civitai.com* || "$url" == *civitai.red* ]] && is_civitai=1

  if [ "$is_civitai" -eq 1 ] && [ -z "$HAVE_CURL" ]; then
    log "  [FAIL] curl is required for Civitai downloads but is not installed: $url"
    FAILED+=("model: (unknown filename) (url: $url) — curl not installed")
    return 1
  fi

  local auth_header=()
if [ "$is_civitai" -eq 1 ] && [ -n "$CIVITAI_API_KEY" ]; then
    auth_header=(-H "Authorization: Bearer $CIVITAI_API_KEY")
elif [[ "$url" == *huggingface.co* ]] && [ -n "$HUGGINGFACE_TOKEN" ]; then
    auth_header=(-H "Authorization: Bearer $HUGGINGFACE_TOKEN")
fi

  local expected_size=0
  local thumb_url=""
  local meta_json=""
  local meta_ok=0

  if [ "$is_civitai" -eq 1 ] && [ -z "$filename" ]; then
    local prefix
    prefix="m$(echo "$url" | md5sum | cut -c1-10)"
    if civitai_fetch_metadata "$url" "$prefix"; then
      meta_ok=1
      filename="$(cat "${META_TMP_DIR}/${prefix}.filename")"
      expected_size="$(cat "${META_TMP_DIR}/${prefix}.size_bytes")"
      thumb_url="$(cat "${META_TMP_DIR}/${prefix}.thumb_url")"
      meta_json="${META_TMP_DIR}/${prefix}.json"
    fi
  fi

  if [ -z "$filename" ] && [ "$is_civitai" -eq 0 ]; then
    # Direct links (e.g. huggingface) — the URL's last path segment
    # is normally the real filename.
    filename="$(basename "${url%%\?*}")"
  fi

  # ---- Case A: filename known ahead of time (explicit, hf, or via
  # Civitai metadata). Duplicate check can happen before downloading.
  if [ -n "$filename" ]; then
    local target_path="${target_dir}/${filename}"
    if [ -f "$target_path" ]; then
      log "  [SKIP] Already exists: $filename"
      SKIPPED+=("model: $filename")
      return 0
    fi

    log "  [DOWNLOAD] $filename -> $target_dir"
    local dl_ok=1
    if [ "$is_civitai" -eq 1 ]; then
      # curl -L handles Civitai's redirect correctly on its own (see
      # the comment on download_with_retry_curl above) -- no manual
      # redirect resolution needed.
      if ! download_with_retry_curl "$url" "$target_path" "${auth_header[@]}"; then
        dl_ok=0
      fi
    else
      if ! download_with_retry "$url" "$target_path" 1 "${auth_header[@]}"; then
        dl_ok=0
      fi
    fi
    if [ "$dl_ok" -eq 1 ]; then
      local actual_size
      actual_size="$(stat -c%s "$target_path" 2>/dev/null || echo 0)"
      # If we know the expected size from Civitai's metadata, require
      # we're within 1% of it (accounts for rounding in their sizeKB
      # field). Otherwise fall back to the basic "bigger than 10KB"
      # sanity check.
      local size_ok=0
      if [ "$expected_size" -gt 0 ]; then
        local min_ok=$(( expected_size * 99 / 100 ))
        [ "$actual_size" -ge "$min_ok" ] && size_ok=1
      elif [ "$actual_size" -gt 10240 ]; then
        size_ok=1
      fi

      if [ "$size_ok" -eq 1 ]; then
        log "  [OK] $filename"
        SUCCEEDED+=("model: $filename")
        if [ "$meta_ok" -eq 1 ]; then
          save_civitai_sidecar "$meta_json" "$thumb_url" "$target_dir" "$filename"
        fi
        maybe_extract_archive "$target_path" "$target_dir"
      else
        log "  [FAIL] $filename downloaded but size looks wrong (got ${actual_size} bytes, expected ~${expected_size}) — removing"
        rm -f "$target_path"
        FAILED+=("model: $filename (url: $url) — incomplete/wrong-size download")
      fi
    else
      log "  [FAIL] $filename — all ${MAX_ATTEMPTS} attempts failed"
      rm -f "$target_path"
      FAILED+=("model: $filename (url: $url)")
    fi
    return 0
  fi

  # ---- Case B: Civitai metadata lookup failed (API down, unusual
  # URL shape, etc). Fall back to downloading into a temp folder and
  # letting wget read the real filename from Content-Disposition.
  # NOTE: wget's -O flag always overrides --content-disposition
  # naming, so this deliberately does NOT use -O / download_with_retry
  # — it lets wget name the file itself, with its own -c/--tries for
  # resume support on large files.
  local b_dl_url="$url"
  local b_dl_auth=("${auth_header[@]}")
  ( cd "$TMP_DL_DIR" && rm -f -- *
    local b_attempt=1
    while [ "$b_attempt" -le "$MAX_ATTEMPTS" ]; do
      if [ "$b_attempt" -gt 1 ]; then
        rm -f -- *
        sleep 5
      fi
      if [ "$is_civitai" -eq 1 ]; then
        # curl -L drops the Authorization header on the cross-host
        # redirect to R2 automatically -- see download_with_retry_curl
        # above for the full explanation. -O -J: use the server's
        # suggested filename (equivalent to wget's --content-disposition).
        curl -fL --retry 2 --retry-delay 5 --connect-timeout 30 \
          --progress-bar -O -J "${b_dl_auth[@]}" "$b_dl_url" 2>&1 | tee -a "$LOG_FILE"
      else
        wget -c --tries=3 --timeout=60 --waitretry=10 \
          --progress=bar:force:noscroll --content-disposition \
          "${b_dl_auth[@]}" "$b_dl_url" 2>&1 | tee -a "$LOG_FILE"
      fi
      b_wget_status="${PIPESTATUS[0]}"
      [ "$b_wget_status" -eq 0 ] && break
      if [ "$b_wget_status" -eq 130 ] || [ "$b_wget_status" -eq 143 ]; then
        exit 130  # exits the subshell only -- caught by the check right after it closes below
      fi
      b_attempt=$((b_attempt + 1))
    done
  )
  # ( )  is a subshell, so an `exit` inside it only ends the subshell,
  # not the whole script -- check its exit status here and trigger
  # the real cleanup-and-stop if it was killed by Ctrl+C/SIGTERM.
  local subshell_status="$?"
  if [ "$subshell_status" -eq 130 ] || [ "$subshell_status" -eq 143 ]; then
    cleanup_and_exit_on_interrupt
  fi

  local downloaded_file
  downloaded_file="$(find "$TMP_DL_DIR" -maxdepth 1 -type f -printf '%f\n' | head -1)"

  if [ -z "$downloaded_file" ]; then
    log "  [FAIL] Download produced no file: $url"
    FAILED+=("model: (unknown filename) (url: $url) — no file was produced")
    return 1
  fi

  local downloaded_size
  downloaded_size="$(stat -c%s "${TMP_DL_DIR}/${downloaded_file}" 2>/dev/null || echo 0)"

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
  log "  [OK] $downloaded_file (no trigger-word metadata — Civitai API lookup failed for this link)"
  SUCCEEDED+=("model: $downloaded_file")
  maybe_extract_archive "$target_path" "$target_dir"
  return 0
}

# Temp folder used only by the Case B fallback path above (when a
# Civitai metadata lookup fails and we have to read the filename off
# the download response instead). Removed at the very end of the
# script.
TMP_DL_DIR="$(mktemp -d)"

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
  "https://civitai.red/api/download/models/3072640?fileId=2951582"
  "https://civitai.red/api/download/models/3027315?fileId=2906064"
  "https://civitai.red/api/download/models/3026211?fileId=2904995"
)
for url in "${EXTENSIONS[@]}"; do
  clone_extension "$url"
done

log "\n== VAE =="
download_file "https://civitai.red/api/download/models/648388?fileId=824329" "$VAE_DIR"
download_file "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors" "$VAE_DIR"

log "\n== Text Encoder =="
download_file "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors" "$TEXT_ENCODER_DIR"

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

log "\n== LoRA =="
LORAS=(
"https://civitai.red/api/download/models/2579082?fileId=2466259"
"https://civitai.red/api/download/models/2177579?fileId=2070697"
"https://civitai.red/api/download/models/2154919?fileId=2048262"
"https://civitai.red/api/download/models/2080703?fileId=1976653"
"https://civitai.red/api/download/models/2979435?fileId=2866837"
"https://civitai.red/api/download/models/2613253?fileId=2500626"
"https://civitai.red/api/download/models/1428568?fileId=1329866"
"https://civitai.red/api/download/models/2319817?fileId=2210102"
"https://civitai.red/api/download/models/2268553?fileId=2160667"
"https://civitai.red/api/download/models/2431103?fileId=2321652"
"https://civitai.red/api/download/models/2653394?fileId=2541219"
"https://civitai.red/api/download/models/2855073?fileId=2741162"
"https://civitai.red/api/download/models/2979642?fileId=2859181"
"https://civitai.red/api/download/models/3184772?fileId=3065310"
"https://civitai.red/api/download/models/2954332?fileId=2833644"
"https://civitai.red/api/download/models/3003728?fileId=2882998"
"https://civitai.red/api/download/models/3026577?fileId=2905342"
"https://civitai.red/api/download/models/2984285?fileId=2863772"
"https://civitai.red/api/download/models/3036905?fileId=2915794"
"https://civitai.red/api/download/models/2885588?fileId=2765348"
"https://civitai.red/api/download/models/3056341?fileId=2935783"
"https://civitai.red/api/download/models/2945421?fileId=2824598"
"https://civitai.red/api/download/models/2945328?fileId=2824501"
"https://civitai.red/api/download/models/3106632?fileId=2986565"
"https://civitai.red/api/download/models/3015331?fileId=2894293"
"https://civitai.red/api/download/models/3053514?fileId=2932217"
"https://civitai.red/api/download/models/2977577?fileId=2857197"
"https://civitai.red/api/download/models/3056172?fileId=2934819"
"https://civitai.red/api/download/models/3109578?fileId=2989582"
"https://civitai.red/api/download/models/3120243?fileId=3000551"
"https://civitai.red/api/download/models/3058132?fileId=2938272"
"https://civitai.red/api/download/models/3050990?fileId=2934234"
"https://civitai.red/api/download/models/3067262?fileId=2946387"
)
for url in "${LORAS[@]}"; do
  download_file "$url" "$LORA_DIR"
done

log "\n== ControlNet =="
CONTROLNET=(
"https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth"
"https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors"
"https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors"
"https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor"
"https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors"
"https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors"
"https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors"
"https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors"
"https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet.safetensors"
"https://huggingface.co/windsingai/Illustrious-XL-Tile/resolve/main/illustriousXL_tile_controlnet_10w.safetensors"
"https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32"
"https://huggingface.co/kohya-ss/Anima-LLLite/blob/main/anima-lllite-depth-1.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/blob/main/anima-lllite-any-test-like-v2.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/blob/main/anima-lllite-inpainting-v2.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/blob/main/anima-lllite-lineart-1.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/blob/main/anima-lllite-pose-1.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/blob/main/anima-lllite-scribble-1.safetensors"
"https://civitai.red/api/download/models/3068951?fileId=2947687"
)
for url in "${CONTROLNET[@]}"; do
  download_file "$url" "$CONTROLNET_DIR"
done

log "\n== Checkpoint =="
download_file "https://civitai.red/api/download/models/2862490?fileId=2746761" "$CHECKPOINT_DIR"
download_file "https://civitai.red/api/download/models/3041842?fileId=2920618" "$CHECKPOINT_DIR"

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
rm -rf "$META_TMP_DIR"
