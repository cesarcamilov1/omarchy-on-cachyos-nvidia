# shellcheck shell=bash
#
# NVIDIA on CachyOS: Omarchy 4.x hardware leaf step.
#
# install-omarchy-on-cachyos.sh copies this file over install/hardware/nvidia.sh
# in the cloned Omarchy tree. omarchy-apply-hardware then runs it through
# run_logged (install/helpers/logging.sh), which sources it in a fresh
# `bash -eE` with stdin redirected from /dev/null. Consequences:
#   - it runs as root: no sudo;
#   - it must never prompt;
#   - any failing command aborts the step, and a failed step aborts
#     omarchy-apply-system, so failures here must be real failures.
# All logic lives in a function so the file works both when sourced (as Omarchy
# does) and when run directly with `sudo bash nvidia.sh` for debugging.
#
# Policy (replaces Omarchy's own nvidia.sh, which installs nvidia-open-dkms or
# nvidia-580xx-dkms by itself):
#   - Blackwell/Hopper GPUs (e.g. GeForce RTX 50 series) only work with the open
#     kernel modules, so they keep CachyOS's default chwd profile (open driver);
#   - every other GPU gets the proprietary 580xx series through CachyOS's chwd:
#     its PCI ID is added to chwd's 580 ID list so chwd selects that profile,
#     and removed packages are restored if chwd fails;
#   - CachyOS's own kernel/initramfs configuration is never rewritten. Only a
#     separate modprobe drop-in is added. No mkinitcpio drop-in is written: the
#     early-KMS module list is left to CachyOS/chwd, so no initramfs rebuild is
#     needed here.
#   - per-session environment variables are NOT written here (this runs as
#     root). The main installer writes them as the user after provisioning.

_cachyos_nvidia_log() {
  echo "[omarchy-on-cachyos/nvidia] $*"
}

_cachyos_nvidia_err() {
  echo "[omarchy-on-cachyos/nvidia] ERROR: $*" >&2
}

# Print the installed NVIDIA userspace driver version (epoch stripped), or
# nothing when no NVIDIA userspace package is installed.
_cachyos_nvidia_driver_version() {
  local pkg version
  for pkg in nvidia-580xx-utils nvidia-utils; do
    if version=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}') && [[ -n $version ]]; then
      echo "${version#*:}"
      return 0
    fi
  done
  return 0
}

# True when a proprietary (non-open) NVIDIA kernel module package is installed:
# either a DKMS build or a CachyOS prebuilt module for a CachyOS kernel.
_cachyos_nvidia_has_proprietary_module() {
  pacman -Qq | grep -Eq '^(nvidia(-580xx)?-dkms|linux-cachyos[a-z0-9-]*-nvidia(-580xx)?)$'
}

_cachyos_nvidia_580xx_active() {
  local version
  version=$(_cachyos_nvidia_driver_version)
  [[ $version == 580.* ]] && _cachyos_nvidia_has_proprietary_module
}

cachyos_nvidia_setup() {
  local ids_file=/var/lib/chwd/ids/nvidia-580.ids
  local gpu_id gpu_name

  if ! lspci -nn -d 10de: | grep -Eq 'VGA|3D'; then
    _cachyos_nvidia_log "No NVIDIA GPU found. Skipping."
    return 0
  fi

  gpu_id=$(lspci -nn -d 10de: | grep -E 'VGA|3D' | head -n1 | grep -oP '(?<=\[10de:)[0-9a-fA-F]{4}(?=\])' || true)
  gpu_name=$(lspci -d 10de: | grep -E 'VGA|3D' | head -n1 | sed 's/.*: //')
  _cachyos_nvidia_log "NVIDIA GPU detected: $gpu_name (ID: ${gpu_id:-unknown})"

  if ! command -v chwd >/dev/null 2>&1; then
    _cachyos_nvidia_err "chwd (CachyOS hardware detection) is not installed; cannot manage the NVIDIA driver."
    return 1
  fi

  # Blackwell (GBxxx) and Hopper (GHxxx) GPUs, e.g. the GeForce RTX 50 series,
  # are only supported by NVIDIA's open kernel modules. The closed 580xx driver
  # cannot drive them, so keep CachyOS's default (open) chwd profile instead.
  if [[ $gpu_name =~ (^|[^A-Za-z0-9])G[BH][0-9]{3}([^0-9]|$) ]]; then
    _cachyos_nvidia_open_only_setup "$ids_file" "$gpu_id" || return 1
  else
    _cachyos_nvidia_580xx_setup "$ids_file" "$gpu_id" || return 1
  fi

  _cachyos_nvidia_common_setup
}

# Open-module-only GPUs: undo a 580xx pin from an earlier run and make sure a
# kernel module is installed through chwd's default profile.
_cachyos_nvidia_open_only_setup() {
  local ids_file=$1 gpu_id=$2

  _cachyos_nvidia_log "This GPU requires NVIDIA's open kernel modules; not pinning the proprietary 580xx driver."

  if [[ -n $gpu_id && -f $ids_file ]] && grep -qiw "$gpu_id" "$ids_file"; then
    _cachyos_nvidia_log "Removing GPU ID $gpu_id from $ids_file (added by an earlier run)."
    sed -i "/^${gpu_id}\$/Id" "$ids_file"
  fi

  if pacman -Qq | grep -Eq '^(nvidia-open-dkms|linux-cachyos[a-z0-9-]*-nvidia-open)$'; then
    _cachyos_nvidia_log "Open NVIDIA kernel module already installed ($(_cachyos_nvidia_driver_version))."
    return 0
  fi

  # Force-reinstall chwd's open profile: when its packages were removed behind
  # chwd's back (e.g. by an earlier 580xx run), `chwd -a` skips the profile as
  # "already installed" and leaves the machine without a kernel module.
  _cachyos_nvidia_log "No NVIDIA kernel module installed. Reinstalling chwd profile nvidia-open-dkms..."
  if ! chwd -f -i nvidia-open-dkms; then
    _cachyos_nvidia_err "chwd could not install nvidia-open-dkms. The NVIDIA driver is missing: fix it before rebooting (see 'chwd --help')."
    return 1
  fi
  if ! pacman -Qq | grep -Eq '^(nvidia-open-dkms|linux-cachyos[a-z0-9-]*-nvidia-open)$'; then
    _cachyos_nvidia_err "chwd finished but no open NVIDIA kernel module is installed. Fix it before rebooting."
    return 1
  fi
  _cachyos_nvidia_log "Open NVIDIA driver installed via chwd ($(_cachyos_nvidia_driver_version))."
}

_cachyos_nvidia_580xx_setup() {
  local ids_file=$1 gpu_id=$2 pkg
  local -a open_packages=()

  # Pin: make chwd's 580 profile match this GPU.
  if [[ -z $gpu_id ]]; then
    _cachyos_nvidia_log "Could not read the GPU PCI ID; leaving $ids_file unchanged."
  elif [[ ! -f $ids_file ]]; then
    _cachyos_nvidia_log "$ids_file not found; chwd will use its own profile selection."
  elif grep -qiw "$gpu_id" "$ids_file"; then
    _cachyos_nvidia_log "GPU ID $gpu_id already present in $ids_file."
  else
    _cachyos_nvidia_log "Adding GPU ID $gpu_id to $ids_file..."
    # Make sure the appended ID starts on its own line.
    if [[ -n $(tail -c1 "$ids_file") ]]; then
      echo >>"$ids_file"
    fi
    echo "$gpu_id" >>"$ids_file"
  fi

  if _cachyos_nvidia_580xx_active; then
    _cachyos_nvidia_log "Proprietary 580xx driver already active ($(_cachyos_nvidia_driver_version)). Keeping it."
  else
    _cachyos_nvidia_log "Proprietary 580xx driver not active (userspace: $(_cachyos_nvidia_driver_version || true))."

    # Open kernel module packages and the current-series userspace conflict with
    # the proprietary 580xx series (chwd's pacman call runs non-interactively, so
    # it cannot answer pacman's "Remove nvidia-utils?" conflict prompt itself).
    for pkg in libxnvctrl linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open nvidia-open-dkms \
      nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia; do
      if pacman -Q "$pkg" >/dev/null 2>&1; then
        open_packages+=("$pkg")
      fi
    done
    if (( ${#open_packages[@]} )); then
      _cachyos_nvidia_log "Removing conflicting packages: ${open_packages[*]}"
      pacman -Rdd --noconfirm "${open_packages[@]}"
    fi

    _cachyos_nvidia_log "Running chwd auto-configuration..."
    if ! chwd -a; then
      _cachyos_nvidia_err "chwd -a failed."
      _cachyos_nvidia_restore_packages "${open_packages[@]}"
      return 1
    fi

    if ! _cachyos_nvidia_580xx_active; then
      _cachyos_nvidia_err "chwd finished but the proprietary 580xx driver is not active (userspace: $(_cachyos_nvidia_driver_version || true))."
      _cachyos_nvidia_err "Install the 580xx profile manually with chwd before rebooting."
      return 1
    fi
    _cachyos_nvidia_log "Proprietary 580xx driver installed via chwd ($(_cachyos_nvidia_driver_version))."
  fi
}

# Reinstall the packages removed before a failed chwd run, so the machine is
# not left without an NVIDIA kernel module.
_cachyos_nvidia_restore_packages() {
  (( $# )) || return 0
  _cachyos_nvidia_log "Restoring removed packages: $*"
  if ! pacman -S --needed --noconfirm "$@"; then
    _cachyos_nvidia_err "Could not restore: $*. The NVIDIA driver may be missing: fix it before rebooting."
  fi
}

_cachyos_nvidia_common_setup() {
  # VA-API: libva-nvidia-driver provides NVDEC-backed VA-API (needed by the
  # browser hardware decoding notes in README.md); libva-utils provides vainfo.
  pacman -S --needed --noconfirm libva-utils libva-nvidia-driver

  # Separate drop-in so CachyOS/chwd files are never overwritten.
  mkdir -p /etc/modprobe.d
  cat >/etc/modprobe.d/omarchy-on-cachyos-nvidia.conf <<'EOF'
# Written by omarchy-on-cachyos (bin/nvidia.sh). Safe to delete.
options nvidia_drm modeset=1
EOF

  _cachyos_nvidia_log "NVIDIA configuration complete."
}

cachyos_nvidia_setup
