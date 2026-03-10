#!/usr/bin/env bash
set -euo pipefail

# WAN2.2 one-shot installer for a local Linux server (Debian/Ubuntu + RHEL-family)
# Usage:
#   chmod +x install_wan22.sh
#   ./install_wan22.sh
#
# Optional env vars:
#   INSTALL_DIR=/opt/Wan2.2     ./install_wan22.sh
#   PYTHON_BIN=python3.11        ./install_wan22.sh
#   STRICT_GPU_CHECK=1           ./install_wan22.sh   # fail if NVIDIA/CUDA checks fail
#   INSTALL_FLASH_ATTN=1         ./install_wan22.sh   # install flash_attn too

REPO_URL="https://github.com/Wan-Video/Wan2.2.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Wan2.2}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${INSTALL_DIR}/.venv"
STRICT_GPU_CHECK="${STRICT_GPU_CHECK:-0}"
INSTALL_FLASH_ATTN="${INSTALL_FLASH_ATTN:-0}"

log() { echo "[WAN2.2-INSTALL] $*"; }
err() { echo "[WAN2.2-INSTALL][ERROR] $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_system_deps_if_possible() {
  local missing=()

  need_cmd git || missing+=(git)
  need_cmd "$PYTHON_BIN" || missing+=(python3)

  if [ ${#missing[@]} -gt 0 ]; then
    log "Some dependencies are missing: ${missing[*]}"

    if need_cmd apt-get; then
      log "Attempting to install missing packages via apt-get..."
      if need_cmd sudo; then
        sudo apt-get update
        sudo apt-get install -y git python3 python3-venv python3-pip
      else
        apt-get update
        apt-get install -y git python3 python3-venv python3-pip
      fi
    elif need_cmd dnf; then
      log "Attempting to install missing packages via dnf..."
      if need_cmd sudo; then
        sudo dnf install -y git python3 python3-pip
      else
        dnf install -y git python3 python3-pip
      fi
    elif need_cmd yum; then
      log "Attempting to install missing packages via yum..."
      if need_cmd sudo; then
        sudo yum install -y git python3 python3-pip
      else
        yum install -y git python3 python3-pip
      fi
    else
      err "No supported package manager found. Please install manually: git, python3, python3-pip, and python3-venv (if needed)."
      exit 1
    fi
  fi

  if ! "$PYTHON_BIN" -m venv --help >/dev/null 2>&1; then
    err "Python venv module is unavailable for $PYTHON_BIN. Install python3-venv/python3-virtualenv and rerun."
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

  log "Continuing installation without strict GPU enforcement. Set STRICT_GPU_CHECK=1 to require NVIDIA+CUDA."
}

clone_or_update_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "Existing WAN2.2 repo found at $INSTALL_DIR. Pulling latest changes..."
    git -C "$INSTALL_DIR" pull --ff-only
  else
    log "Cloning WAN2.2 into $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
}

setup_venv_and_install() {
  log "Creating/updating Python virtual environment..."
  "$PYTHON_BIN" -m venv "$VENV_DIR"

  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  log "Upgrading pip/setuptools/wheel..."
  python -m pip install --upgrade pip setuptools wheel

  if [ ! -f "$INSTALL_DIR/requirements.txt" ]; then
    err "requirements.txt not found in $INSTALL_DIR"
    exit 1
  fi

  local filtered_requirements
  filtered_requirements="$(mktemp)"

  if [ "$INSTALL_FLASH_ATTN" = "1" ]; then
    log "Installing all Python requirements (including flash_attn)..."
    cp "$INSTALL_DIR/requirements.txt" "$filtered_requirements"
  else
    log "Installing Python requirements (skipping flash_attn by default)..."
    grep -Ev '^[[:space:]]*flash_attn([[:space:]]|[<>=!~]|$)' "$INSTALL_DIR/requirements.txt" > "$filtered_requirements"
  fi

  pip install -r "$filtered_requirements"
  rm -f "$filtered_requirements"

  deactivate
}

print_next_steps() {
  cat <<EOF

✅ WAN2.2 installation finished.

Location:
  $INSTALL_DIR

Virtualenv:
  $VENV_DIR

To use it:
  source "$VENV_DIR/bin/activate"
  cd "$INSTALL_DIR"

If WAN2.2 needs model files, download them according to the official repo instructions.
EOF
}

main() {
  log "Starting WAN2.2 installation..."
  install_system_deps_if_possible
  check_nvidia_cuda
  clone_or_update_repo
  setup_venv_and_install
  print_next_steps
}

main "$@"
