#!/bin/bash
#
# Fetch an Omarchy 4.x source tree into the directory the installer uses.
#
# Omarchy 4.x lives at github.com/omacom/omarchy. Only stable 4.x tags
# (vMAJOR.MINOR.PATCH, no -rc/-beta suffix) are offered, newest first. The
# installer (install-omarchy-on-cachyos.sh) validates that the resulting tree is
# a 4.x layout before using it, so keeping an existing directory is allowed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${OMARCHY_DIR:-$SCRIPT_DIR/../../omarchy}"
REPO_URL="https://github.com/omacom/omarchy"
MAX_RELEASES=10

die() {
  echo "Error: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is not installed."

echo "Fetching available stable Omarchy 4.x releases from $REPO_URL..."
if ! remote_tags=$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null); then
  die "Could not list tags from $REPO_URL. Check your network connection."
fi

# Keep only stable 4.x tags (v4.X.Y). Pre-releases such as v4.5.0-rc1 or
# v4.0.0-beta3 are excluded on purpose.
mapfile -t RELEASES < <(
  printf '%s\n' "$remote_tags" |
    awk -F/ '{print $3}' |
    grep -E '^v4\.[0-9]+\.[0-9]+$' |
    sort -rV |
    head -n "$MAX_RELEASES"
)

if (( ${#RELEASES[@]} == 0 )); then
  die "No stable Omarchy 4.x release tags were found at $REPO_URL."
fi

BLEEDING_CHOICE=$(( ${#RELEASES[@]} + 1 ))

echo "-----------------------------------------------"
echo "Select the Omarchy version you want to install:"
echo "-----------------------------------------------"
for i in "${!RELEASES[@]}"; do
  label="Stable Release (${RELEASES[i]})"
  (( i == 0 )) && label="$label [default, newest]"
  echo "$((i + 1))) $label"
done
echo "$BLEEDING_CHOICE) Bleeding Edge (default branch - Unstable, untested with this installer)"

read -r -p "Enter your choice (1-$BLEEDING_CHOICE) [1]: " CHOICE
CHOICE="${CHOICE:-1}"

if ! [[ $CHOICE =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > BLEEDING_CHOICE )); then
  die "Invalid choice '$CHOICE'. Expected a number between 1 and $BLEEDING_CHOICE."
fi

CLONE_ARGS=()
if (( CHOICE == BLEEDING_CHOICE )); then
  echo "Selected bleeding-edge default branch."
else
  SELECTED_TAG="${RELEASES[$((CHOICE - 1))]}"
  CLONE_ARGS=(--depth 1 --branch "$SELECTED_TAG")
  echo "Selected stable version: $SELECTED_TAG"
fi

# Ensure the target directory is clean before cloning to prevent fatal conflicts.
if [[ -e $TARGET_DIR ]]; then
  echo ""
  echo "Warning: an existing Omarchy source directory was found at $TARGET_DIR"
  read -r -p "Delete it and clone the selected version? [y/N]: " CONFIRM
  if [[ ${CONFIRM,,} =~ ^(y|yes)$ ]]; then
    echo "Removing $TARGET_DIR..."
    rm -rf "$TARGET_DIR"
  else
    # Keep the existing tree. The installer validates that it is a 4.x layout
    # and aborts with a clear message otherwise.
    echo "Keeping the existing files in $TARGET_DIR (the selection above is ignored)."
    exit 0
  fi
fi

echo "Cloning into $TARGET_DIR..."
if ! git -c advice.detachedHead=false clone --quiet "${CLONE_ARGS[@]}" "$REPO_URL" "$TARGET_DIR"; then
  die "Failed to clone $REPO_URL."
fi

echo "Successfully cloned the Omarchy source tree."
