#!/usr/bin/env bash
# =============================================================================
# SilentGuard Engine — macOS Installer
# Downloads the packaged binary from a private GitHub Releases repo,
# verifies it, extracts it, downloads ONNX + PII models from HuggingFace,
# sets up XDG-standard directory layout, and writes the Chrome Native
# Messaging Host manifest.
# =============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
VERSION="${SILENTGUARD_VERSION:-v0.0.1}"
GITHUB_REPO="PromptProwl/silentguard-releases"
# Repo is public, so no PAT is needed
BINARY_NAME="silentguard-mac"
ASSET_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${VERSION}"

# Chrome extension ID that will talk to this host
CHROME_EXTENSION_ID="cmhlaimhneoganidnfcodmplhfeoball"

# Hugging Face model coordinates
EMBEDDING_REPO="gpahal/bge-m3-onnx-int8"
EMBEDDING_FILE="model_quantized.onnx"

PII_REPO="teimurjan/tanaos-text-anonymizer-onnx"
PII_FILE="onnx/model_quantized.onnx"

# ─── XDG-style paths (mirrors engine/config.py — macOS uses same ~/.local/… tree) ─
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

MODELS_DIR="${XDG_DATA_HOME}/silentguard/models"
DB_DIR="${XDG_STATE_HOME}/silentguard/db"
CACHE_DIR="${XDG_CACHE_HOME}/silentguard"
LOGS_DIR="${XDG_STATE_HOME}/silentguard/logs"
CONFIG_DIR="${XDG_CONFIG_HOME}/silentguard"
APP_DIR="${XDG_DATA_HOME}/silentguard/app/current"
BIN_DIR="${XDG_DATA_HOME}/silentguard/bin"

# Chrome NativeMessaging host directories (per-user, macOS)
CHROME_NMH_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
CHROMIUM_NMH_DIR="$HOME/Library/Application Support/Chromium/NativeMessagingHosts"

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
err()   { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || err "Required command '$1' not found. Please install it."
}

# ─── Pre-flight checks ──────────────────────────────────────────────────────
require_cmd curl
require_cmd shasum
require_cmd jq

info "SilentGuard Engine Installer — macOS (${VERSION})"
echo ""

# ─── Step 1: Create directory structure ──────────────────────────────────────
info "Creating directories in ~/.local/share, ~/.local/state, ~/.config, ~/.cache..."

for dir in "$MODELS_DIR" "$DB_DIR" "$CACHE_DIR" "$LOGS_DIR" "$CONFIG_DIR" "$APP_DIR" "$BIN_DIR"; do
    printf '   Creating %s\n' "$dir"
    mkdir -p "$dir"
done
ok "Directory structure created."
echo ""

# ─── Step 2: Download the binary package from GitHub Releases ────────────────
info "Fetching release metadata for ${VERSION} from ${GITHUB_REPO}..."

RELEASE_JSON=$(curl -sSL \
    -H "Accept: application/vnd.github+json" \
    "${ASSET_URL}")

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | jq -r \
    ".assets[] | select(.name == \"${BINARY_NAME}\") | .url")

[ -z "$DOWNLOAD_URL" ] && err "Binary '${BINARY_NAME}' not found in release ${VERSION}."

info "Downloading ${BINARY_NAME}..."
DOWNLOAD_DEST="${CACHE_DIR}/${BINARY_NAME}"
curl -SL --progress-bar \
    -H "Accept: application/octet-stream" \
    "$DOWNLOAD_URL" \
    -o "$DOWNLOAD_DEST"
ok "Download complete → ${DOWNLOAD_DEST}"
echo ""

# ─── Step 3: Verify SHA-256 checksum ────────────────────────────────────────
CHECKSUM_URL=$(echo "$RELEASE_JSON" | jq -r \
    ".assets[] | select(.name == \"${BINARY_NAME}.sha256\") | .url")

if [ -n "$CHECKSUM_URL" ] && [ "$CHECKSUM_URL" != "null" ]; then
    info "Verifying SHA-256 checksum..."
    EXPECTED_HASH=$(curl -sSL \
        -H "Accept: application/octet-stream" \
        "$CHECKSUM_URL" | awk '{print $1}')

    ACTUAL_HASH=$(shasum -a 256 "$DOWNLOAD_DEST" | awk '{print $1}')
    if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
        err "Checksum mismatch!\n  Expected: ${EXPECTED_HASH}\n  Actual:   ${ACTUAL_HASH}"
    fi
    ok "SHA-256 checksum verified."
else
    info "No .sha256 asset found in release — computing and displaying checksum for reference."
    shasum -a 256 "$DOWNLOAD_DEST"
fi
echo ""

# ─── Step 4: Install binary ─────────────────────────────────────────────────
info "Installing binary to ${APP_DIR}..."
cp "$DOWNLOAD_DEST" "${APP_DIR}/${BINARY_NAME}"
chmod +x "${APP_DIR}/${BINARY_NAME}"

# Symlink into BIN_DIR for convenience
ln -sf "${APP_DIR}/${BINARY_NAME}" "${BIN_DIR}/silentguard-engine"
ok "Binary installed → ${APP_DIR}/${BINARY_NAME}"
ok "Symlink created  → ${BIN_DIR}/silentguard-engine"
echo ""

# ─── Step 5: Write Chrome Native Messaging Host manifest ────────────────────
info "Writing Chrome Native Messaging Host manifest..."

NMH_JSON=$(cat <<EOF
{
  "name": "ai.silentguard.host",
  "description": "SilentGuard Engine — local AI inference for browser privacy",
  "path": "${APP_DIR}/${BINARY_NAME}",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://${CHROME_EXTENSION_ID}/"
  ]
}
EOF
)

for nmh_dir in "$CHROME_NMH_DIR" "$CHROMIUM_NMH_DIR"; do
    mkdir -p "$nmh_dir"
    echo "$NMH_JSON" > "${nmh_dir}/ai.silentguard.host.json"
    printf '   Wrote %s/ai.silentguard.host.json\n' "$nmh_dir"
done
ok "Chrome Native Messaging Host manifest installed."
echo ""

# ─── Step 6: Download models from Hugging Face ──────────────────────────────
info "Downloading ONNX embedding model from Hugging Face..."
info "  Repository: ${EMBEDDING_REPO}"
info "  File:       ${EMBEDDING_FILE}"

EMBEDDING_MODEL_DIR="${MODELS_DIR}/${EMBEDDING_REPO}"
mkdir -p "$EMBEDDING_MODEL_DIR"
curl -SL --progress-bar \
    "https://huggingface.co/${EMBEDDING_REPO}/resolve/main/${EMBEDDING_FILE}" \
    -o "${EMBEDDING_MODEL_DIR}/${EMBEDDING_FILE}"
ok "Embedding model downloaded → ${EMBEDDING_MODEL_DIR}/${EMBEDDING_FILE}"

# Also download tokenizer files needed by transformers
info "Downloading tokenizer files for embedding model..."
for TOKENIZER_FILE in tokenizer.json tokenizer_config.json special_tokens_map.json config.json; do
    TOKENIZER_URL="https://huggingface.co/${EMBEDDING_REPO}/resolve/main/${TOKENIZER_FILE}"
    HTTP_STATUS=$(curl -sL -o "${EMBEDDING_MODEL_DIR}/${TOKENIZER_FILE}" -w "%{http_code}" "$TOKENIZER_URL")
    if [ "$HTTP_STATUS" = "200" ]; then
        printf '   Downloaded %s\n' "$TOKENIZER_FILE"
    else
        printf '   Skipped %s (not found)\n' "$TOKENIZER_FILE"
        rm -f "${EMBEDDING_MODEL_DIR}/${TOKENIZER_FILE}"
    fi
done
echo ""

info "Downloading PII detection model from Hugging Face..."
info "  Repository: ${PII_REPO}"
info "  File:       ${PII_FILE}"

PII_MODEL_DIR="${MODELS_DIR}/${PII_REPO}"
PII_FILE_DIR=$(dirname "${PII_FILE}")
mkdir -p "${PII_MODEL_DIR}/${PII_FILE_DIR}"
curl -SL --progress-bar \
    "https://huggingface.co/${PII_REPO}/resolve/main/${PII_FILE}" \
    -o "${PII_MODEL_DIR}/${PII_FILE}"
ok "PII model downloaded → ${PII_MODEL_DIR}/${PII_FILE}"

# Download PII tokenizer/config files into the repo root
info "Downloading tokenizer files for PII model..."
for TOKENIZER_FILE in tokenizer.json tokenizer_config.json special_tokens_map.json config.json vocab.txt; do
    TOKENIZER_URL="https://huggingface.co/${PII_REPO}/resolve/main/${TOKENIZER_FILE}"
    HTTP_STATUS=$(curl -sL -o "${PII_MODEL_DIR}/${TOKENIZER_FILE}" -w "%{http_code}" "$TOKENIZER_URL")
    if [ "$HTTP_STATUS" = "200" ]; then
        printf '   Downloaded %s\n' "$TOKENIZER_FILE"
    else
        printf '   Skipped %s (not found)\n' "$TOKENIZER_FILE"
        rm -f "${PII_MODEL_DIR}/${TOKENIZER_FILE}"
    fi
done
echo ""

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
ok "═══════════════════════════════════════════════════════════"
ok "  SilentGuard Engine installed successfully!"
ok "═══════════════════════════════════════════════════════════"
echo ""
info "Directory layout:"
echo "   Binary:      ${APP_DIR}/${BINARY_NAME}"
echo "   Symlink:     ${BIN_DIR}/silentguard-engine"
echo "   Models:      ${MODELS_DIR}/"
echo "   Database:    ${DB_DIR}/"
echo "   Logs:        ${LOGS_DIR}/"
echo "   Config:      ${CONFIG_DIR}/"
echo "   Cache:       ${CACHE_DIR}/"
echo ""
info "To start the engine:"
echo "   ${BIN_DIR}/silentguard-engine"
echo ""
