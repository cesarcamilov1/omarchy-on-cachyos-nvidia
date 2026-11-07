#!/bin/bash
#
# Install Omarchy 4.x on top of an existing CachyOS (+ NVIDIA) system.
#
# Omarchy 4.x ships as pacman packages (omarchy-keyring, omarchy-settings,
# omarchy) from the [omarchy] repository, with OMARCHY_PATH=/usr/share/omarchy.
# Its target-side setup runs through two entry points:
#   - bin/omarchy-apply-system --install-user USER --first-install   (root)
#   - bin/omarchy-provision-user --first-install                     (user)
#
# This script:
#   1. fetches a 4.x source tree (bin/fetch-omarchy.sh) and validates it;
#   2. checks CachyOS preconditions (Limine boot stack, display manager);
#   3. configures pacman: durable NoExtract entries for package files that
#      conflict with CachyOS, then the [omarchy] repo after the CachyOS repos;
#   4. installs the Omarchy packages and a filtered default package set;
#   5. patches the CLONED tree (never /usr/share/omarchy) and runs
#      omarchy-apply-system from it as root;
#   6. seeds the existing user's home from /etc/skel (missing files only) and
#      runs omarchy-provision-user from the installed package as the user;
#   7. writes NVIDIA session variables and fish mise activation for the user.
#
# Run it as your normal user. It uses sudo for the root parts.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="${OMARCHY_DIR:-$SCRIPT_DIR/../../omarchy}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/var/backups/omarchy-on-cachyos/$TIMESTAMP"
USER_BACKUP_DIR="$HOME/.local/state/omarchy-on-cachyos/backup-$TIMESTAMP"
INSTALL_LOG="/var/log/omarchy-install.log"

# Omarchy stable channel (evidence: v4.5.0 bin/omarchy-upgrade-to-quattro:323
# and default/pacman/pacman-stable.conf).
# shellcheck disable=SC2016 # $arch is expanded by pacman, not by this shell.
OMARCHY_REPO_SERVER='https://pkgs.omarchy.org/stable/$arch'
# Omarchy packaging key (evidence: v4.5.0 bin/omarchy-upgrade-to-quattro:453).
OMARCHY_KEY="40DFB630FF42BCFFB047046CF0134EE680CAC571"

# Package-owned files that must never be extracted on CachyOS. Paths are
# relative to / as pacman's NoExtract expects. Evidence (Omarchy v4.5.0):
#   - omarchy-settings copies the repo etc/ tree to /etc
#     (omarchy-pkgs pkgbuilds/omarchy-settings/PKGBUILD: `cp -a etc/. "$pkgdir/etc/"`,
#     docs/file-layout.md "etc/** -> /etc/**").
#   - omarchy installs default/libalpm/hooks/00-omarchy-update-guard.hook to
#     /usr/share/libalpm/hooks/ (omarchy-pkgs pkgbuilds/omarchy/PKGBUILD).
NOEXTRACT_PATHS=(
  # Replaces the whole HOOKS array (plymouth, encrypt, btrfs-overlayfs...).
  etc/mkinitcpio.conf.d/00-omarchy-hooks.conf
  # Rewrites HOOKS (drops kms on NVIDIA-only machines) and FILES.
  etc/mkinitcpio.conf.d/omarchy_hooks.conf
  # Limine entry defaults: UKI, "quiet splash", Omarchy boot order and name.
  etc/limine-entry-tool.d/omarchy-defaults.conf
  etc/limine-entry-tool.d/omarchy-uki.conf
  # Aborts every direct `pacman -Syu` / `yay -Syu` (bin/omarchy-update-pacman-guard).
  usr/share/libalpm/hooks/00-omarchy-update-guard.hook
)
NOEXTRACT_BEGIN="# BEGIN omarchy-on-cachyos NoExtract"
NOEXTRACT_END="# END omarchy-on-cachyos NoExtract"

INSTALL_USER="$(id -un)"
OMARCHY_TAG=""
BASE_PACKAGES=()
SUDO_KEEPALIVE_PID=""

log() {
  echo -e "\n==> $*"
}

warn() {
  echo -e "\033[33mWarning:\033[0m $*" >&2
}

die() {
  echo -e "\033[31mError:\033[0m $*" >&2
  exit 1
}

confirm() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ ${answer,,} =~ ^(y|yes)$ ]]
}

cleanup() {
  if [[ -n $SUDO_KEEPALIVE_PID ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'echo -e "\033[31mError:\033[0m command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  local cmd

  (( EUID != 0 )) || die "Run this script as your normal user, not as root. It uses sudo when needed."
  [[ $(uname -m) == "x86_64" ]] || die "Only x86_64 CachyOS is supported."

  for cmd in git sudo pacman pacman-key pacman-conf lspci awk sed grep cp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' is not installed."
  done

  # /etc/os-release is replaced by omarchy-settings, so detect CachyOS through
  # its repositories instead (this also works when the script is re-run).
  if ! grep -q '^cachyos' <<<"$(pacman-conf --repo-list)"; then
    die "No CachyOS repositories found in /etc/pacman.conf. This installer only supports CachyOS."
  fi

  if [[ $(findmnt -n -o FSTYPE / 2>/dev/null || true) != "btrfs" ]]; then
    warn "The root filesystem is not btrfs. Omarchy expects btrfs + snapper."
    confirm "Continue anyway?" || exit 1
  fi

  log "Requesting sudo access"
  sudo -v || die "sudo authentication failed."
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null || true
      sleep 60
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

# ---------------------------------------------------------------------------
# Omarchy source tree
# ---------------------------------------------------------------------------

fetch_omarchy_tree() {
  local required

  log "Fetching the Omarchy 4.x source tree"
  [[ -f $SCRIPT_DIR/fetch-omarchy.sh ]] || die "$SCRIPT_DIR/fetch-omarchy.sh is missing."
  OMARCHY_DIR="$OMARCHY_DIR" bash "$SCRIPT_DIR/fetch-omarchy.sh"

  [[ -d $OMARCHY_DIR ]] || die "No Omarchy source tree at $OMARCHY_DIR."
  OMARCHY_DIR="$(cd "$OMARCHY_DIR" && pwd)"

  # A 3.x tree (install.sh layout) or anything else must not be used.
  for required in \
    bin/omarchy-apply-system \
    bin/omarchy-apply-hardware \
    bin/omarchy-provision-user \
    install/helpers/logging.sh \
    install/omarchy-base.packages \
    install/config/all.sh \
    install/hardware/all.sh \
    install/hardware/nvidia.sh \
    install/post-install/all.sh; do
    if [[ ! -e $OMARCHY_DIR/$required ]]; then
      die "$OMARCHY_DIR is not an Omarchy 4.x tree (missing $required).
Delete it and re-run this script, choosing a 4.x release."
    fi
  done

  OMARCHY_TAG="$(git -C "$OMARCHY_DIR" describe --tags --exact-match 2>/dev/null || true)"
  echo "Using Omarchy source tree: $OMARCHY_DIR (${OMARCHY_TAG:-not a release tag})"
}

# ---------------------------------------------------------------------------
# CachyOS preconditions
# ---------------------------------------------------------------------------

check_boot_stack() {
  local -a missing=()

  log "Checking the boot stack"
  # The published x86_64 omarchy package hard-depends on the Limine stack
  # (omarchy-pkgs pkgbuilds/omarchy/PKGBUILD depends_x86_64; the [omarchy]
  # repo database for omarchy 4.5.0 lists limine, limine-mkinitcpio-hook,
  # limine-snapper-sync and snapper). limine-mkinitcpio-hook takes over kernel
  # and initramfs deployment, so it must not land on a systemd-boot/GRUB/rEFInd
  # installation.
  if ! pacman -T limine >/dev/null; then
    die "Limine is not installed. Omarchy 4.x on x86_64 depends on the Limine boot stack
(limine, limine-mkinitcpio-hook, limine-snapper-sync, snapper), which would replace
how your kernels are installed. Reinstall CachyOS with the Limine boot loader first."
  fi

  # pacman -T prints the unsatisfied dependencies (and exits 127 when any).
  mapfile -t missing < <(pacman -T limine-mkinitcpio-hook limine-snapper-sync snapper || true)
  if (( ${#missing[@]} )); then
    warn "These Omarchy dependencies are not installed yet and will be pulled in:"
    printf '  - %s\n' "${missing[@]}"
    warn "limine-mkinitcpio-hook takes over kernel/initramfs deployment for Limine."
    confirm "Continue and let pacman install them?" || exit 1
  fi
}

check_display_manager() {
  local current

  # omarchy-apply-system enables sddm.service (install/config/enable-services.sh),
  # which fails when another display manager owns display-manager.service.
  # No symlink means no display manager is enabled (e.g. a "No Desktop" CachyOS
  # install). GNU readlink -f still prints a path for a missing file, so check
  # for the symlink first to avoid treating "display-manager.service" itself as a DM.
  [[ -L /etc/systemd/system/display-manager.service ]] || return 0
  current="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
  current="${current##*/}"
  if [[ -n $current && $current != "sddm.service" ]]; then
    warn "$current is the active display manager. Omarchy 4.x uses SDDM."
    if confirm "Disable $current so SDDM can be enabled?"; then
      sudo systemctl disable "$current"
    else
      die "Cannot continue while $current owns display-manager.service."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

backup_system_files() {
  local file

  log "Backing up system files to $BACKUP_DIR"
  sudo install -d -m 0755 "$BACKUP_DIR"
  sudo cp -a /etc/pacman.conf "/etc/pacman.conf.omarchy-on-cachyos-$TIMESTAMP.bak"

  # omarchy-settings' post_install scriptlet overwrites these with cp -f on
  # every install/upgrade (omarchy-settings.install _etc_overrides_apply), so
  # NoExtract cannot protect them. Keep the CachyOS versions for reference.
  for file in /etc/pacman.conf /etc/os-release /etc/nsswitch.conf \
    /etc/security/faillock.conf /etc/plymouth/plymouthd.conf /etc/sddm.conf; do
    if [[ -e $file ]]; then
      sudo cp -aL "$file" "$BACKUP_DIR/$(echo "${file#/}" | tr / _)"
    fi
  done
  if [[ -L /etc/os-release ]]; then
    readlink /etc/os-release | sudo tee "$BACKUP_DIR/etc_os-release.symlink-target" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# pacman
# ---------------------------------------------------------------------------

configure_pacman_noextract() {
  local tmp

  log "Adding NoExtract entries for conflicting Omarchy package files"
  tmp="$(mktemp)"
  # Re-runs replace the marked block, so the list stays current.
  if ! awk \
    -v paths="${NOEXTRACT_PATHS[*]}" \
    -v begin="$NOEXTRACT_BEGIN" \
    -v end="$NOEXTRACT_END" '
    BEGIN { n = split(paths, list, " "); in_block = 0; written = 0 }
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block { next }
    { print }
    /^[[:space:]]*\[options\][[:space:]]*$/ && !written {
      print begin
      print "# Omarchy package files that conflict with CachyOS. See omarchy-on-cachyos README."
      for (i = 1; i <= n; i++) print "NoExtract = " list[i]
      print end
      written = 1
    }
    END { if (!written) exit 3 }
  ' /etc/pacman.conf >"$tmp"; then
    rm -f "$tmp"
    die "No [options] section found in /etc/pacman.conf."
  fi
  sudo install -m 0644 "$tmp" /etc/pacman.conf
  rm -f "$tmp"
}

configure_omarchy_repo() {
  local tmp

  log "Configuring the [omarchy] repository (after the CachyOS and Arch repositories)"
  tmp="$(mktemp)"
  # Drop any existing [omarchy] section (older installers used a wrong URL),
  # then append the stable one at the end. pacman resolves a package from the
  # first repository that has it, so CachyOS/Arch builds keep precedence.
  awk -v server="$OMARCHY_REPO_SERVER" '
    /^[[:space:]]*\[omarchy\][[:space:]]*$/ { skip = 1; next }
    /^[[:space:]]*\[/ { skip = 0 }
    !skip { print }
    END {
      print ""
      print "[omarchy]"
      print "# Added by omarchy-on-cachyos. Kept last on purpose: CachyOS/Arch packages win."
      print "Server = " server
    }
  ' /etc/pacman.conf | cat -s >"$tmp"
  sudo install -m 0644 "$tmp" /etc/pacman.conf
  rm -f "$tmp"
}

verify_pacman_config() {
  local path repos noextract

  # Output is captured first: `cmd | grep -q` can fail under pipefail (SIGPIPE).
  repos="$(pacman-conf --repo-list)"
  noextract="$(pacman-conf NoExtract)"
  grep -qx omarchy <<<"$repos" || die "[omarchy] repository is not active in /etc/pacman.conf."
  for path in "${NOEXTRACT_PATHS[@]}"; do
    grep -qxF "$path" <<<"$noextract" || die "NoExtract entry for $path is not active."
  done
}

setup_omarchy_keyring() {
  log "Trusting the Omarchy packaging key and installing omarchy-keyring"
  if ! sudo pacman-key --list-keys "$OMARCHY_KEY" >/dev/null 2>&1; then
    sudo pacman-key --recv-keys "$OMARCHY_KEY" --keyserver hkps://keys.openpgp.org ||
      sudo pacman-key --recv-keys "$OMARCHY_KEY" ||
      die "Could not receive the Omarchy packaging key $OMARCHY_KEY."
  fi
  sudo pacman-key --lsign-key "$OMARCHY_KEY"
  sudo pacman -Sy --needed --noconfirm omarchy-keyring
}

check_package_version() {
  local pkg_version

  # --print-format is not localized, unlike `pacman -Si`.
  pkg_version="$(pacman -Sddp --print-format '%v' omarchy 2>/dev/null || true)"
  pkg_version="${pkg_version#*:}"
  pkg_version="${pkg_version%-*}"
  [[ -n $pkg_version ]] || die "The omarchy package was not found in the [omarchy] repository."

  if [[ -z $OMARCHY_TAG ]]; then
    warn "The source tree is not a release tag, but the repository serves omarchy $pkg_version."
    confirm "Run setup steps from an untagged tree against omarchy $pkg_version?" || exit 1
  elif [[ ${OMARCHY_TAG#v} != "$pkg_version" ]]; then
    warn "The source tree is $OMARCHY_TAG, but the repository serves omarchy $pkg_version."
    warn "Setup steps from the tree may not match the installed package."
    confirm "Continue anyway? (Re-running and choosing v$pkg_version is safer)" || exit 1
  fi
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_omarchy_packages() {
  log "Installing omarchy-keyring, omarchy-settings and omarchy (full system upgrade)"
  # Interactive on purpose: conflict prompts (for example against CachyOS
  # packages) are answered by you, not silently.
  sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --needed omarchy-keyring omarchy-settings omarchy
  pacman -Q omarchy omarchy-settings >/dev/null || die "Omarchy packages are not installed."
  [[ -d /usr/share/omarchy ]] || die "/usr/share/omarchy is missing after installing omarchy."
}

remove_preexisting_noextract_files() {
  local path

  # NoExtract only stops future extraction. A file left by an earlier install
  # (before NoExtract was set) is removed here; NoExtract keeps it away later.
  for path in "${NOEXTRACT_PATHS[@]}"; do
    if [[ -e /$path ]]; then
      warn "Removing /$path (backed up to $BACKUP_DIR)."
      sudo cp -a "/$path" "$BACKUP_DIR/$(echo "$path" | tr / _)"
      sudo rm -f "/$path"
    fi
  done
}

build_base_package_list() {
  local pkg
  local -a raw=() skipped=() missing=()
  local -A available=()

  log "Building the filtered Omarchy default package list"
  mapfile -t raw < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$OMARCHY_DIR/install/omarchy-base.packages")
  while read -r pkg; do
    available[$pkg]=1
  done < <(pacman -Slq)

  for pkg in "${raw[@]}"; do
    case "$pkg" in
      tldr)
        # CachyOS ships tealdeer, which conflicts with tldr.
        skipped+=("$pkg (CachyOS uses tealdeer)")
        continue
        ;;
      omarchy-power-profiles-daemon)
        # Omarchy's fork exists for ARM laptops (comment in
        # install/omarchy-base.packages) and conflicts with CachyOS's stock
        # power-profiles-daemon.
        skipped+=("$pkg (keeps CachyOS power-profiles-daemon)")
        continue
        ;;
      linux-omarchy* | limine* | nvidia* | lib32-nvidia* | *-dkms | iwd)
        # Kernel, boot loader, NVIDIA driver and Wi-Fi daemon stay CachyOS's
        # (NVIDIA is handled by chwd in bin/nvidia.sh). None of these are in
        # the 4.5.0 base list; the filter guards future lists.
        skipped+=("$pkg (owned by CachyOS)")
        continue
        ;;
    esac
    if [[ -z ${available[$pkg]:-} ]]; then
      missing+=("$pkg")
      continue
    fi
    BASE_PACKAGES+=("$pkg")
  done

  # install/config/enable-services.sh enables power-profiles-daemon.service.
  if ! pacman -T power-profiles-daemon >/dev/null; then
    BASE_PACKAGES+=(power-profiles-daemon)
  fi

  if (( ${#skipped[@]} )); then
    echo "Skipped on purpose:"
    printf '  - %s\n' "${skipped[@]}"
  fi
  if (( ${#missing[@]} )); then
    warn "Not found in any configured repository (skipped):"
    printf '  - %s\n' "${missing[@]}" >&2
  fi
}

install_base_packages() {
  (( ${#BASE_PACKAGES[@]} )) || return 0
  log "Installing the Omarchy default package set (${#BASE_PACKAGES[@]} packages, --needed)"
  # All of these come from pacman repositories (Arch, CachyOS, [omarchy]), so
  # no AUR helper is needed. Interactive so conflicts are answered by you.
  sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed "${BASE_PACKAGES[@]}"
}

# ---------------------------------------------------------------------------
# SDDM
# ---------------------------------------------------------------------------

move_cachyos_sddm_conf() {
  local owner

  # SDDM reads /etc/sddm.conf after /etc/sddm.conf.d/, so a CachyOS
  # /etc/sddm.conf overrides Omarchy's 10-theme.conf / 10-wayland.conf drop-ins.
  [[ -f /etc/sddm.conf ]] || return 0
  owner="$(pacman -Qoq /etc/sddm.conf 2>/dev/null || true)"
  log "Moving /etc/sddm.conf to $BACKUP_DIR so Omarchy's SDDM drop-ins apply"
  sudo mv /etc/sddm.conf "$BACKUP_DIR/sddm.conf.moved"
  if [[ -n $owner ]]; then
    warn "/etc/sddm.conf belongs to package '$owner' and may come back when it is upgraded."
  fi
}

# ---------------------------------------------------------------------------
# Omarchy setup
# ---------------------------------------------------------------------------

patch_omarchy_tree() {
  log "Adjusting the cloned Omarchy setup steps for CachyOS"
  cd "$OMARCHY_DIR"

  # post-install/pacman.sh runs bin/omarchy-apply-pacman, which overwrites
  # /etc/pacman.conf and the mirrorlist (drops the CachyOS repositories).
  sed -i '\|/post-install/pacman\.sh"|d' install/post-install/all.sh
  # config/snapper.sh overwrites the snapper root config and enables
  # limine-snapper-sync. CachyOS keeps its own snapper setup.
  sed -i '\|/config/snapper\.sh"|d' install/config/all.sh
  # Omarchy's nvidia.sh installs nvidia-open/580xx DKMS itself; use chwd instead.
  install -m 0644 "$SCRIPT_DIR/nvidia.sh" install/hardware/nvidia.sh

  ! grep -q 'post-install/pacman\.sh' install/post-install/all.sh || die "Failed to patch install/post-install/all.sh."
  ! grep -q 'config/snapper\.sh' install/config/all.sh || die "Failed to patch install/config/all.sh."
  cmp -s "$SCRIPT_DIR/nvidia.sh" install/hardware/nvidia.sh || die "Failed to replace install/hardware/nvidia.sh."
  cd - >/dev/null
}

run_apply_system() {
  log "Running omarchy-apply-system from $OMARCHY_DIR (log: $INSTALL_LOG)"
  # omarchy-apply-system and omarchy-apply-hardware honour OMARCHY_PATH /
  # OMARCHY_INSTALL and put $OMARCHY_PATH/bin first on PATH (v4.5.0
  # bin/omarchy-apply-system:83-86), so the patched steps above are used.
  if ! sudo env \
    OMARCHY_PATH="$OMARCHY_DIR" \
    OMARCHY_INSTALL="$OMARCHY_DIR/install" \
    OMARCHY_INSTALL_LOG_FILE="$INSTALL_LOG" \
    OMARCHY_USER_NAME="$OMARCHY_USER_NAME" \
    OMARCHY_USER_EMAIL="$OMARCHY_USER_EMAIL" \
    "$OMARCHY_DIR/bin/omarchy-apply-system" --install-user "$INSTALL_USER" --first-install; then
    echo "Last lines of $INSTALL_LOG:" >&2
    sudo tail -n 40 "$INSTALL_LOG" >&2 || true
    die "omarchy-apply-system failed. Fix the problem above and re-run this script."
  fi
}

seed_user_home() {
  log "Seeding $HOME from /etc/skel (missing files only)"
  # useradd -m is what normally copies /etc/skel (docs/file-layout.md "Seed");
  # an existing CachyOS user never got Omarchy's copy, and
  # omarchy-provision-user does not copy ~/.config.
  #
  # A CachyOS Hyprland config without hyprland.lua is not Omarchy's Lua
  # config; move it aside so Omarchy's hypr/ is used.
  if [[ -d $HOME/.config/hypr && ! -e $HOME/.config/hypr/hyprland.lua ]]; then
    mkdir -p "$USER_BACKUP_DIR"
    mv "$HOME/.config/hypr" "$USER_BACKUP_DIR/hypr"
    echo "Moved existing ~/.config/hypr to $USER_BACKUP_DIR/hypr"
  fi
  # --update=none never overwrites existing files (coreutils >= 9.3).
  cp -a --no-preserve=ownership --update=none /etc/skel/. "$HOME/"
}

run_provision_user() {
  log "Running omarchy-provision-user as $INSTALL_USER"
  # Uses the installed package (/usr/share/omarchy), not the clone: the user
  # steps need no patches, and provision-user symlinks agent skills into
  # $OMARCHY_PATH (bin/omarchy-provision-user:88-96), which must not point
  # at a source tree that may be deleted later.
  env -u OMARCHY_PATH -u OMARCHY_INSTALL \
    OMARCHY_USER_NAME="$OMARCHY_USER_NAME" \
    OMARCHY_USER_EMAIL="$OMARCHY_USER_EMAIL" \
    /usr/bin/omarchy-provision-user --first-install
}

configure_user_nvidia_env() {
  local env_file="$HOME/.config/uwsm/env.d/90-omarchy-on-cachyos-nvidia"

  grep -Eq 'VGA|3D' <<<"$(lspci -nn -d 10de:)" || return 0

  # Forcing NVIDIA VA-API/GLX on a hybrid laptop (display on the iGPU) breaks
  # video in Chromium-based browsers (v4.5.0 default/hypr/nvidia.lua).
  if command -v omarchy-hw-nvidia-display >/dev/null 2>&1 && ! omarchy-hw-nvidia-display; then
    warn "NVIDIA does not drive the display (hybrid graphics); skipping NVIDIA session variables."
    return 0
  fi

  log "Writing NVIDIA session variables to $env_file"
  # Omarchy's uwsm env recommends ~/.config/uwsm/env.d/* for user overrides
  # (v4.5.0 default/uwsm/env.d/10-omarchy).
  mkdir -p "$(dirname "$env_file")"
  cat >"$env_file" <<'EOF'
# Written by omarchy-on-cachyos (proprietary NVIDIA 580xx). Changes need a re-login.
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
}

configure_fish_mise() {
  local config="$HOME/.config/fish/config.fish"
  local marker="# omarchy-on-cachyos: mise activation"

  # Omarchy activates mise for bash and the uwsm session only.
  mkdir -p "$(dirname "$config")"
  if grep -qF "$marker" "$config" 2>/dev/null; then
    return 0
  fi
  log "Adding mise activation to $config"
  cat >>"$config" <<EOF

$marker
if command -q mise
    mise activate fish | source
end
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

preflight
fetch_omarchy_tree
check_boot_stack
check_display_manager

default_name="$(getent passwd "$INSTALL_USER" | cut -d: -f5 | cut -d, -f1)"
default_email="$(git config --global user.email 2>/dev/null || true)"
echo ""
read -r -p "Your full name [${default_name}]: " OMARCHY_USER_NAME
OMARCHY_USER_NAME="${OMARCHY_USER_NAME:-$default_name}"
read -r -p "Your email address [${default_email}]: " OMARCHY_USER_EMAIL
OMARCHY_USER_EMAIL="${OMARCHY_USER_EMAIL:-$default_email}"
export OMARCHY_USER_NAME OMARCHY_USER_EMAIL

cat <<EOF

About to install Omarchy ${OMARCHY_TAG:-(untagged tree)} for user '$INSTALL_USER':
  1. Back up /etc/pacman.conf and related files to $BACKUP_DIR.
  2. Add NoExtract entries to /etc/pacman.conf [options] so these package files
     are never installed:
$(printf '       /%s\n' "${NOEXTRACT_PATHS[@]}")
  3. Add the [omarchy] stable repository AFTER the CachyOS/Arch repositories.
  4. Install omarchy-keyring, omarchy-settings, omarchy (with pacman -Syu) and
     the Omarchy default packages (without tldr and Omarchy's power-profiles fork).
  5. Run Omarchy's system setup from the cloned tree, without its pacman.conf
     rewrite and snapper setup, using chwd for NVIDIA 580xx.
  6. Seed your home from /etc/skel (missing files only) and run Omarchy's user setup.

Note: omarchy-settings replaces /etc/os-release, /etc/nsswitch.conf,
/etc/security/faillock.conf and /etc/plymouth/plymouthd.conf on every upgrade.
EOF
read -r -p "Press Enter to begin, or Ctrl+C to abort... "

backup_system_files
configure_pacman_noextract
configure_omarchy_repo
verify_pacman_config
setup_omarchy_keyring
check_package_version
install_omarchy_packages
remove_preexisting_noextract_files
build_base_package_list
install_base_packages
move_cachyos_sddm_conf
patch_omarchy_tree
run_apply_system
seed_user_home
run_provision_user
configure_user_nvidia_env
configure_fish_mise

cat <<EOF

Omarchy installation finished.
  - Backups:      $BACKUP_DIR (pacman.conf also at /etc/pacman.conf.omarchy-on-cachyos-$TIMESTAMP.bak)
  - Setup log:    $INSTALL_LOG
  - Update with:  omarchy update   (direct pacman -Syu / yay -Syu also work)

Review any errors above, then reboot and pick "Omarchy (Hyprland uwsm)" in SDDM.
EOF
