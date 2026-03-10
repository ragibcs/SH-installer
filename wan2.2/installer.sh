#!/usr/bin/env bash
set -euo pipefail

# WAN2.2 full installer: deps + model download + web server launch
# Supports Debian/Ubuntu and RHEL-family (dnf/yum)
#
# Usage:
#   chmod +x install_wan22.sh
#   ./install_wan22.sh
#
# Optional env vars:
#   INSTALL_DIR=/opt/Wan2.2
#   PYTHON_BIN=/usr/bin/python3
#   HF_TOKEN=hf_xxx
#   MODEL_REPO=Wan-AI/Wan2.2-TI2V-5B
#   MODEL_DIR=/home/ubuntu/Wan2.2-Models/Wan2.2-TI2V-5B
#   WEBUI_DIR=/home/ubuntu/Wan2.2-WebUI
#   WEB_HOST=0.0.0.0
#   WEB_PORT=7860
#   INSTALL_FLASH_ATTN=0
#   STRICT_GPU_CHECK=0
#   AUTO_START_WEBUI=1

REPO_URL="https://github.com/Wan-Video/Wan2.2.git"
WEBUI_REPO_URL="https://huggingface.co/spaces/Wan-AI/Wan2.2-Animate"

INSTALL_DIR="${INSTALL_DIR:-$HOME/Wan2.2}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${INSTALL_DIR}/.venv"
STRICT_GPU_CHECK="${STRICT_GPU_CHECK:-0}"
INSTALL_FLASH_ATTN="${INSTALL_FLASH_ATTN:-0}"

MODEL_REPO="${MODEL_REPO:-Wan-AI/Wan2.2-TI2V-5B}"
MODEL_NAME="${MODEL_REPO##*/}"
MODEL_DIR="${MODEL_DIR:-$HOME/Wan2.2-Models/$MODEL_NAME}"
HF_TOKEN="${HF_TOKEN:-}"

WEBUI_DIR="${WEBUI_DIR:-$HOME/Wan2.2-WebUI}"
WEB_HOST="${WEB_HOST:-0.0.0.0}"
WEB_PORT="${WEB_PORT:-7860}"
AUTO_START_WEBUI="${AUTO_START_WEBUI:-1}"
WEBUI_LOG="${WEBUI_DIR}/webui.log"

log() { echo "[WAN2.2-INSTALL] $*"; }
err() { echo "[WAN2.2-INSTALL][ERROR] $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_pkg_install() {
  if need_cmd apt-get; then
    if need_cmd sudo; then
      sudo apt-get update
      sudo apt-get install -y "$@"
    else
      apt-get update
      apt-get install -y "$@"
    fi
  elif need_cmd dnf; then
    if need_cmd sudo; then
      sudo dnf install -y "$@"
    else
      dnf install -y "$@"
    fi
  elif need_cmd yum; then
    if need_cmd sudo; then
      sudo yum install -y "$@"
    else
      yum install -y "$@"
    fi
  else
    err "No supported package manager found. Install manually: $*"
    exit 1
  fi
}

install_system_deps_if_possible() {
  local missing=()
  need_cmd git || missing+=(git)
  need_cmd "$PYTHON_BIN" || missing+=(python3)
  need_cmd pip || true

  if [ ${#missing[@]} -gt 0 ]; then
    log "Installing core system dependencies..."
    run_pkg_install git python3 python3-pip python3-venv curl
  fi

  # helpful for HF space clones and large files
  if ! need_cmd git-lfs; then
    log "Installing git-lfs..."
    run_pkg_install git-lfs || true
  fi

  if need_cmd git-lfs; then
    git lfs install || true
  fi

  if ! "$PYTHON_BIN" -m venv --help >/dev/null 2>&1; then
    err "Python venv module unavailable for $PYTHON_BIN. Install python3-venv/python3-virtualenv and rerun."
    exit 1
  fi
}

check_nvidia_cuda() {
  log "Running NVIDIA/CUDA preflight checks..."
  local gpu_ok=0
  local cuda_ok=0

  if need_cmd nvidia-smi; then
    gpu_ok=1
    log "NVIDIA driver detected:"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
  else
    err "nvidia-smi not found (NVIDIA driver may be missing)."
  fi

  if need_cmd nvcc; then
    cuda_ok=1
    log "CUDA toolkit detected:"
    nvcc --version | tail -n 1 || true
  else
    err "nvcc not found (CUDA toolkit may be missing)."
  fi

  if [ "$gpu_ok" -eq 1 ] && [ "$cuda_ok" -eq 1 ]; then
    log "NVIDIA/CUDA checks passed."
    return 0
  fi

  if [ "$STRICT_GPU_CHECK" = "1" ]; then
    err "STRICT_GPU_CHECK=1 and GPU/CUDA checks failed. Aborting."
    exit 1
  fi

  log "Continuing without strict GPU enforcement."
}

clone_or_update_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "WAN2.2 repo exists at $INSTALL_DIR. Pulling latest..."
    git -C "$INSTALL_DIR" pull --ff-only
  else
    log "Cloning WAN2.2 repo..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
}

setup_venv_and_install() {
  log "Creating/updating venv..."
  "$PYTHON_BIN" -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  log "Upgrading pip tools..."
  python -m pip install --upgrade pip setuptools wheel

  if [ ! -f "$INSTALL_DIR/requirements.txt" ]; then
    err "requirements.txt not found in $INSTALL_DIR"
    exit 1
  fi

  log "Installing base WAN2.2 requirements..."
  local filtered_requirements
  filtered_requirements="$(mktemp)"

  if [ "$INSTALL_FLASH_ATTN" = "1" ]; then
    cp "$INSTALL_DIR/requirements.txt" "$filtered_requirements"
  else
    grep -Ev '^[[:space:]]*flash_attn([[:space:]]|[<>=!~]|$)' "$INSTALL_DIR/requirements.txt" > "$filtered_requirements"
  fi

  pip install -r "$filtered_requirements"
  rm -f "$filtered_requirements"

  log "Installing Hugging Face CLI..."
  pip install -U "huggingface_hub[cli]"

  deactivate
}

download_model() {
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  if [ -n "$HF_TOKEN" ]; then
    log "Logging in to Hugging Face with token..."
    huggingface-cli login --token "$HF_TOKEN"
  else
    log "HF_TOKEN not set. Attempting anonymous model download (works for public models)."
  fi

  mkdir -p "$MODEL_DIR"
  log "Downloading model $MODEL_REPO to $MODEL_DIR ..."
  huggingface-cli download "$MODEL_REPO" --local-dir "$MODEL_DIR" --resume-download

  deactivate
}

setup_webui() {
  if [ -d "$WEBUI_DIR/.git" ]; then
    log "WebUI repo exists at $WEBUI_DIR. Pulling latest..."
    git -C "$WEBUI_DIR" pull --ff-only || true
  else
    log "Cloning Wan2.2 web UI repo..."
    mkdir -p "$(dirname "$WEBUI_DIR")"
    git clone "$WEBUI_REPO_URL" "$WEBUI_DIR"
  fi

  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  if [ -f "$WEBUI_DIR/requirements.txt" ]; then
    log "Installing WebUI requirements..."
    pip install -r "$WEBUI_DIR/requirements.txt"
  fi

  deactivate
}

start_webui() {
  if [ "$AUTO_START_WEBUI" != "1" ]; then
    log "AUTO_START_WEBUI=0, skipping web server startup."
    return 0
  fi

  if [ ! -f "$WEBUI_DIR/app.py" ]; then
    err "WebUI app.py not found at $WEBUI_DIR/app.py"
    err "Install completed, but web server was not started."
    return 0
  fi

  log "Starting WebUI on ${WEB_HOST}:${WEB_PORT} ..."
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  cd "$WEBUI_DIR"
  nohup env WAN_MODEL_DIR="$MODEL_DIR" GRADIO_SERVER_NAME="$WEB_HOST" GRADIO_SERVER_PORT="$WEB_PORT" \
    python app.py > "$WEBUI_LOG" 2>&1 &

  deactivate
  sleep 2

  log "WebUI started. Log: $WEBUI_LOG"
}

print_next_steps() {
  cat <<EOF

✅ WAN2.2 full install finished.

WAN2.2 code:
  $INSTALL_DIR

Python venv:
  $VENV_DIR

Model:
  $MODEL_REPO
  $MODEL_DIR

Web UI:
  $WEBUI_DIR
  http://$(hostname -I 2>/dev/null | awk '{print $1}'):${WEB_PORT}

If remote access is blocked, open firewall/security group for TCP ${WEB_PORT}.
EOF
}

main() {
  log "Starting WAN2.2 full installation..."
  install_system_deps_if_possible
  check_nvidia_cuda
  clone_or_update_repo
  setup_venv_and_install
  download_model
  setup_webui
  start_webui
  print_next_steps
}

main "$@"
