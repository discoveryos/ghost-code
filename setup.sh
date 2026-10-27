#!/usr/bin/env bash
# Ghost Code setup (cross-platform: Linux, macOS, WSL, Windows)
set -euo pipefail

cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || pwd)")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

OS="$(uname -s)"
ARCH="$(uname -m)"
IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
  IS_WSL=1
fi

info "Detected: OS=$OS ARCH=$ARCH WSL=$IS_WSL"

MODELS_DIR="${GHOST_CODER_MODELS_DIR:-$HOME/.ghost-coder/models}"
DEFAULT_MODEL="${GHOST_CODER_MODEL:-qwen2.5-coder-1.5b}"
mkdir -p "$MODELS_DIR"

HAS_NVIDIA=0
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi -L 2>/dev/null | grep -q "GPU"; then
    HAS_NVIDIA=1
    info "NVIDIA GPU detected via nvidia-smi"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -2 || true
  fi
fi
if [ "$IS_WSL" -eq 1 ] && [ "$HAS_NVIDIA" -eq 0 ]; then
  if [ -e /dev/dxg ] 2>/dev/null || ls /usr/lib/wsl/* 2>/dev/null | grep -q nvidia; then
    HAS_NVIDIA=1
    info "NVIDIA GPU detected in WSL (dxg/passthrough)"
  fi
fi

HAS_CUDA_TOOLKIT=0
command -v nvcc >/dev/null 2>&1 && HAS_CUDA_TOOLKIT=1

info "Installing npm dependencies..."
if command -v npm >/dev/null 2>&1; then
  npm install --no-audit --no-fund || npm install --no-audit --no-fund --ignore-scripts || true
elif command -v pnpm >/dev/null 2>&1; then
  pnpm install --ignore-scripts || true
elif command -v yarn >/dev/null 2>&1; then
  yarn install --ignore-scripts || true
else
  err "No npm/pnpm/yarn found. Install Node.js first."
  exit 1
fi

NLC_VERSION="3.22.1"
install_backend() {
  if [ "$OS" = "Linux" ] && [ "$ARCH" = "x86_64" ]; then
    if [ "$HAS_NVIDIA" -eq 1 ]; then
      info "Installing node-llama-cpp CUDA backend for Linux x64..."
      npm install "@node-llama-cpp/linux-x64-cuda@$NLC_VERSION" 2>/dev/null || true
    else
      info "Installing node-llama-cpp CPU/Vulkan backend for Linux x64..."
      npm install "@node-llama-cpp/linux-x64@$NLC_VERSION" 2>/dev/null || true
      npm install "@node-llama-cpp/linux-x64-vulkan@$NLC_VERSION" 2>/dev/null || true
    fi
  elif [ "$OS" = "Linux" ] && [ "$ARCH" = "aarch64" ]; then
    info "Installing node-llama-cpp backend for Linux arm64..."
    npm install "@node-llama-cpp/linux-arm64@$NLC_VERSION" 2>/dev/null || true
  elif [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
    info "Installing node-llama-cpp Metal backend for macOS arm64..."
    npm install "@node-llama-cpp/mac-arm64-metal@$NLC_VERSION" 2>/dev/null || true
  elif [ "$OS" = "Darwin" ] && [ "$ARCH" = "x86_64" ]; then
    info "Installing node-llama-cpp backend for macOS x64..."
    npm install "@node-llama-cpp/mac-x64@$NLC_VERSION" 2>/dev/null || true
  elif [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]] || [[ "$OS" == CYGWIN* ]]; then
    if [ "$HAS_NVIDIA" -eq 1 ]; then
      info "Installing node-llama-cpp CUDA backend for Windows x64..."
      npm install "@node-llama-cpp/win-x64-cuda@$NLC_VERSION" 2>/dev/null || true
    else
      info "Installing node-llama-cpp backend for Windows x64..."
      npm install "@node-llama-cpp/win-x64@$NLC_VERSION" 2>/dev/null || true
    fi
  else
    warn "Unknown platform $OS/$ARCH. Trying to build from source if possible."
  fi
}

install_backend

info "Running node-llama-cpp postinstall..."
if [ -f node_modules/node-llama-cpp/dist/cli/cli.js ]; then
  node node_modules/node-llama-cpp/dist/cli/cli.js postinstall 2>&1 | tail -15 || true
fi

if [ -f node_modules/node-llama-cpp/dist/cli/cli.js ]; then
  info "Checking GPU/device detection..."
  node node_modules/node-llama-cpp/dist/cli/cli.js inspect gpu 2>&1 | head -40 || true
fi

info "Building Ghost Code..."
if command -v bun >/dev/null 2>&1; then
  bun run build 2>&1 | tail -10
else
  npm run build 2>&1 | tail -10
fi
ok "Build complete"

MODEL_FILE=""
REPO=""
case "$DEFAULT_MODEL" in
  qwen2.5-coder-1.5b) MODEL_FILE="qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"; REPO="Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF" ;;
  qwen2.5-coder-7b)   MODEL_FILE="qwen2.5-coder-7b-instruct-q4_k_m.gguf";   REPO="Qwen/Qwen2.5-Coder-7B-Instruct-GGUF" ;;
  llama-3.2-3b)       MODEL_FILE="Llama-3.2-3B-Instruct-Q4_K_M.gguf";     REPO="bartowski/Llama-3.2-3B-Instruct-GGUF" ;;
  qwen2.5-1.5b)       MODEL_FILE="qwen2.5-1.5b-instruct-q4_k_m.gguf";       REPO="Qwen/Qwen2.5-1.5B-Instruct-GGUF" ;;
  tinyllama-1.1b)     MODEL_FILE="tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf";   REPO="TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF" ;;
  *) warn "Unknown model $DEFAULT_MODEL, skipping auto-download"; REPO=""; MODEL_FILE="" ;;
esac

if [ -n "$MODEL_FILE" ] && [ ! -f "$MODELS_DIR/$MODEL_FILE" ]; then
  if [ -n "$REPO" ] && command -v curl >/dev/null 2>&1; then
    info "Downloading $DEFAULT_MODEL..."
    URL="https://huggingface.co/$REPO/resolve/main/$MODEL_FILE"
    if [ -n "${HF_TOKEN:-}" ]; then
      curl -L --progress-bar -H "Authorization: Bearer $HF_TOKEN" -o "$MODELS_DIR/$MODEL_FILE.part" "$URL" && mv "$MODELS_DIR/$MODEL_FILE.part" "$MODELS_DIR/$MODEL_FILE"
    else
      curl -L --progress-bar -o "$MODELS_DIR/$MODEL_FILE.part" "$URL" && mv "$MODELS_DIR/$MODEL_FILE.part" "$MODELS_DIR/$MODEL_FILE"
    fi
    ok "Downloaded to $MODELS_DIR/$MODEL_FILE"
  else
    warn "Download manually or run: /models install $DEFAULT_MODEL"
  fi
elif [ -n "$MODEL_FILE" ] && [ -f "$MODELS_DIR/$MODEL_FILE" ]; then
  ok "Model already present: $MODELS_DIR/$MODEL_FILE"
fi

echo ""
ok "Setup complete!"
echo ""
echo "To run Ghost Code:"
if [ "$IS_WSL" -eq 1 ] || [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]] || [[ "$OS" == CYGWIN* ]]; then
  echo "  Terminal 1: node server.js"
  echo "  Terminal 2: LOCAL_LLM_BASE_URL=http://127.0.0.1:8787/v1 node cli.js"
  echo "  or: ./start.sh"
else
  echo "  ./start.sh"
fi
echo ""
echo "GPU: $([ "$HAS_NVIDIA" -eq 1 ] && echo 'NVIDIA detected - CUDA' || echo 'No NVIDIA auto-detected')"
