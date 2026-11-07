#!/bin/bash
set -e

# --- NVIDIA Configuration for Omarchy on CachyOS ---
# Philosophy: detect and use whatever NVIDIA driver CachyOS has installed.
# Only install a driver if none is present. Never downgrade or force replace.

if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "[*] No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_ID=$(lspci -nn -d 10de: | grep -E "VGA|3D" | head -n1 | grep -oP '(?<=\[10de:)[0-9a-fA-F]{4}(?=\])' || true)
GPU_NAME=$(lspci -d 10de: | grep -E "VGA|3D" | head -n1 | sed 's/.*: //')
echo "[*] Found NVIDIA ID: $GPU_ID"
echo "[*] NVIDIA GPU detected: $GPU_NAME"

echo "[*] Removing conflicting open-driver packages..."
sudo pacman -Rdd --noconfirm libxnvctrl linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open nvidia-open-dkms 2>/dev/null || true

if ! grep -q "$GPU_ID" /var/lib/chwd/ids/nvidia-580.ids; then
    echo "[*] Patching chwd ID list..."
    if [ -n "$(tail -c1 /var/lib/chwd/ids/nvidia-580.ids)" ]; then
        sudo sh -c "echo >> /var/lib/chwd/ids/nvidia-580.ids"
    fi
    sudo sed -i "\$a $GPU_ID" /var/lib/chwd/ids/nvidia-580.ids
else
    echo "[*] GPU ID already present in 580 list."
fi

NVIDIA_DRIVER=$(pacman -Qq | grep -E '^nvidia-(dkms|open-dkms|utils)$' | head -n1 || true)

if [[ -n "$NVIDIA_DRIVER" ]]; then
    DRIVER_VERSION=$(pacman -Q "$NVIDIA_DRIVER" 2>/dev/null | awk '{print $2}')
    echo "[*] Active NVIDIA driver found: $NVIDIA_DRIVER $DRIVER_VERSION"
    echo "[*] Respecting existing CachyOS driver installation."
else
    echo "[!] No NVIDIA driver detected — installing via chwd..."
    sudo chwd -a
    echo "[*] Driver installed via CachyOS hardware detection."
fi

sudo pacman -S --needed --noconfirm libva-utils

mkdir -p "$HOME/.config/uwsm"
if ! grep -q "GBM_BACKEND=nvidia-drm" "$HOME/.config/uwsm/env" 2>/dev/null; then
    cat >>"$HOME/.config/uwsm/env" <<'EOF'
# NVIDIA
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
    echo "[*] NVIDIA environment variables written to ~/.config/uwsm/env"
else
    echo "[*] NVIDIA environment variables already present."
fi

echo "[*] NVIDIA configuration complete."